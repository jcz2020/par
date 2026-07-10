<!-- language: zh -->
[English](../sdk/document_loaders.md) · **简体中文**

# 文档加载器

> 在 v0.7.0 (beta) 中添加。真实来源：`lib/documents/document.mli`、`lib/documents/*_loader.mli` 和 `lib/documents/directory_loader.mli` 中的 OCaml 类型。

PAR 的文档加载器将真实文件（文本、Markdown、HTML、CSV、PDF）转换为 `Document.t` 记录，直接接入 RAG 管道。加载 PDF，用 `Chunking` 分块，用 `Runtime.embed` 嵌入向量，存入 `Vector_store`，再通过 `Runtime.invoke_with_rag` 查询。加载器处理文件 I/O、格式解析和元数据提取，让你专注于管道本身。

完整的 RAG 管道（embeddings、向量存储、分块、检索）见 [RAG API](rag.md)。文档加载器产出的 `Document.t` 值直接馈入该管道。

## Document 类型

加载后的文档是一个包含三个字段的记录：

```ocaml
type t = {
  content : string;    (** extracted plain text *)
  metadata : (string, Yojson.Safe.t) Hashtbl.t;  (** source-derived fields *)
  source : string;     (** file path or URI *)
}
```

`content` 字段是提取出的纯文本。`source` 字段是原始文件路径或 URI。`metadata` 哈希表保存加载器从源文件获取的所有信息：文件名、文件大小、页码、列值、YAML frontmatter 等。

`metadata` 的类型是 `(string, Yojson.Safe.t) Hashtbl.t`，与 `Vector_store.document` 的 metadata 字段类型一致。这意味着加载器输出可以直接传递给 `Vector_store.add`，无需转换。

### 元数据辅助函数

`Meta` 子模块提供便捷的构造方法：

```ocaml
open Par.Document.Meta

let m = empty ()                          (* 创建空哈希表 *)
let m = singleton "source" (`String "a.md")  (* 单条目哈希表 *)
add m "page" (`Int 3)                     (* 添加 Yojson 值 *)
add_string m "file_type" "text/markdown"   (* String 的简写 *)
add_int m "file_size" 4096                (* Int 的简写 *)

(* 在 Yojson 之间往返转换 *)
let json = to_yojson m in
let m' = of_yojson json
```

### 加载错误

加载器失败时返回 `Load_error.t` 变体：

| 变体 | 含义 |
|------|------|
| `File_not_found of string` | 文件在给定路径不存在 |
| `Permission_denied of string` | 文件存在但无法读取 |
| `Unsupported_format of string` | 加载器不支持该文件类型 |
| `Extraction_failed of string * string` | 解析或提取失败（消息、异常信息） |
| `Workspace_rejected of Types.error_category` | 路径被 `Workspace.admit` 拒绝（安全检查） |

使用 `Document.load_error_to_string` 获取人类可读的错误消息：

```ocaml
let print_error err =
  prerr_endline (Document.load_error_to_string err)
```

## 加载器 `make` 模式

每个格式加载器都遵循两阶段构造函数模式：

```ocaml
module My_loader : sig
  val make : Workspace.workspace -> string ->
    (unit -> Document.t list, Document.load_error) result
end
```

`make` 接受一个 workspace（用于路径安全验证）和文件路径。成功时返回一个 thunk，调用时读取文件并产出 `Document.t list`。如果路径无效，`make` 本身立即返回 `Error`，不读取任何文件。提取过程中的异常会被优雅捕获（记录日志，返回空列表）。

### 实现自定义加载器

要添加新文件格式的支持，编写一个满足加载器构造函数模式的模块。每个内置加载器都遵循这种形状：

```ocaml
module My_loader : sig
  val make : Workspace.workspace -> string ->
    (unit -> Document.t list, Document.load_error) result
end
```

`make` 接受一个 workspace（用于路径安全验证）和文件路径。成功时返回一个 thunk，调用时读取文件并产出 `Document.t list`。失败时返回 `load_error`。

一个最小的自定义加载器：

```ocaml
open Par

let make ws path =
  match Workspace.admit ws path with
  | Error e -> Error (Document.Workspace_rejected e)
  | Ok sandboxed ->
    let full_path = Workspace.to_string sandboxed in
    Ok (fun () ->
      let ic = open_in full_path in
      Fun.protect
        ~finally:(fun () -> close_in ic)
        (fun () ->
          let content = really_input_string ic (in_channel_length ic) in
          let meta = Document.Meta.empty () in
          Document.Meta.add_string meta "file_type" "application/x-myformat";
          Ok [{ Document.content; metadata = meta; source = path }]))
```

## 内置加载器

PAR 提供五个格式加载器。每个从单个文件产出 `Document.t list`。

### Text_loader (.txt)

读取纯文本文件，产出一个带标准元数据的 `Document.t`。

```ocaml
open Par

let ws = Workspace.of_cwd () in
match Text_loader.make ws "notes.txt" with
| Error e -> prerr_endline (Document.load_error_to_string e)
| Ok load ->
  let docs = load () in
  Printf.printf "Loaded %d document(s)\n" (List.length docs)
```

**元数据字段：** `file_path`、`file_name`、`file_size`、`file_type = "text/plain"`。

### Markdown_loader (.md)

通过 `Omd.of_string` 解析 Markdown 并遍历 AST 提取纯文本（标题、段落、代码块、列表）。文件开头 `---` 分隔符之间的 YAML frontmatter 通过 `Yaml.of_string` 解析，与标准字段合并到元数据中。

```ocaml
open Par

let ws = Workspace.of_cwd () in
match Markdown_loader.make ws "README.md" with
| Error e -> prerr_endline (Document.load_error_to_string e)
| Ok load ->
  let docs = load () in
  List.iter (fun doc ->
    Printf.printf "Source: %s\n" doc.Document.source;
    Printf.printf "Content length: %d\n" (String.length doc.Document.content)
  ) docs
```

**元数据字段：** `file_path`、`file_name`、`file_size`、`file_type = "text/markdown"`，加上任何 YAML frontmatter 键值对。

### Html_loader (.html)

读取 HTML 文件，去除 `<script>` 和 `<style>` 元素，通过 lambdasoup 提取可见文本内容。

```ocaml
open Par

let ws = Workspace.of_cwd () in
match Html_loader.make ws "page.html" with
| Error e -> prerr_endline (Document.load_error_to_string e)
| Ok load ->
  let docs = load () in
  Printf.printf "Extracted %d document(s)\n" (List.length docs)
```

**元数据字段：** `file_path`、`file_name`、`file_size`、`file_type = "text/html"`。

### Csv_loader (.csv)

读取 CSV 文件。表头行定义列名。每行数据（不含表头）产出一个 `Document.t`：

- `content`：按 `"column_name: value\n"` 格式排列的键值行。
- `metadata`：每个列名以 `csv_` 为前缀映射到其值（作为 `String`），加上 `row_index`、`file_path`、`file_name`、`file_size`、`file_type = "text/csv"`。
- `source`：输入文件路径。

```ocaml
open Par

let ws = Workspace.of_cwd () in
match Csv_loader.make ws "users.csv" with
| Error e -> prerr_endline (Document.load_error_to_string e)
| Ok load ->
  let docs = load () in
  Printf.printf "Loaded %d rows as documents\n" (List.length docs)
```

### Pdf_loader (.pdf)

使用 camlpdf 的简单文本流提取从 PDF 中提取文本。每页产出一个 `Document.t`，`metadata["page"]` 设为页码。

```ocaml
open Par

let ws = Workspace.of_cwd () in
match Pdf_loader.make ws "paper.pdf" with
| Error e -> prerr_endline (Document.load_error_to_string e)
| Ok load ->
  let docs = load () in
  Printf.printf "Extracted %d pages\n" (List.length docs)
```

**元数据字段：** `file_path`、`file_name`、`file_size`、`file_type = "application/pdf"`、`page`（int，从 1 开始）。

#### 局限性

!!! warning "范围妥协 — 见 ROADMAP v0.7.0 第 2 节 #9"

    PDF 加载器使用简单文本流提取，**而非**布局保留提取。这是一个有意的范围妥协，附有退役计划。

    - **不保留布局：** 多栏 PDF 产出交错文本。列在输出中被混合在一起。
    - **不支持 OCR：** 扫描件或纯图片 PDF 无法提取任何内容。此加载器背后没有 Tesseract 或 OCR 引擎。
    - **表格和复杂布局**可能产出质量较差的输出。

    这覆盖了大约 80% 的文本型 PDF（单栏或简单布局的研究论文、文档、报告）。

    **布局感知提取的触发条件：** 如果下游集成报告失败率超过 20%，或者 v0.8 规划开始时（以先到者为准）。迁移路径是替换 `Pdf_loader.extract_text` 的内部实现而不更改公共接口，因为 `Document.t -> Document.t` 契约保持不变。

    **.docx（Word）支持**推迟到 v0.7.1。目前没有维护中的 OCaml Word 文档库，DIY 实现会很脆弱。完整推后理由见 ROADMAP v0.7.0 第 4 节。

## Directory_loader

目录加载器递归扫描目录树，根据文件扩展名将每个文件分发到对应的格式加载器。循环符号链接会被检测并跳过。

```ocaml
open Par

let ws = Workspace.of_cwd () in
match Directory_loader.load ws "docs/" with
| Error e -> prerr_endline (Document.load_error_to_string e)
| Ok docs ->
  Printf.printf "Loaded %d documents from directory\n" (List.length docs)
```

**`default_map`** 覆盖 `.txt`、`.md`、`.html`、`.csv` 和 `.pdf`。未知扩展名通过 `Logs.warn` 跳过。单个文件的错误会被记录并跳过（扫描不会中止）。

### 自定义扩展名映射

你可以覆盖或扩展映射表：

```ocaml
open Par

(* 为 .json 文件添加自定义加载器 *)
let json_loader ws path =
  match Workspace.admit ws path with
  | Error e -> Error (Document.Workspace_rejected e)
  | Ok () ->
    Ok (fun () ->
      let ic = open_in path in
      let content = really_input_string ic (in_channel_length ic) in
      close_in ic;
      let meta = Document.Meta.empty () in
      Document.Meta.add_string meta "file_type" "application/json";
      [{ Document.content; metadata = meta; source = path }])

let my_map = (".json", json_loader) :: Directory_loader.default_map in
match Directory_loader.load ws ~map:my_map "data/" with
| Error e -> prerr_endline (Document.load_error_to_string e)
| Ok docs -> Printf.printf "Loaded %d documents\n" (List.length docs)
```

`loader_fn` 的类型是 `Workspace.workspace -> string -> (unit -> Document.t list, Document.load_error) result`，与每个内置加载器的 `make` 函数签名一致。

## 与 RAG 的组合

完整管道：加载文档，分块，嵌入向量，存储向量，通过 `invoke_with_rag` 查询。

```ocaml
open Par
open Types

let ws = Workspace.of_cwd () in

(* 1. 从目录加载文档 *)
let docs = Directory_loader.load ws ~map:Directory_loader.default_map "knowledge_base/"
  |> Result.get_ok in

(* 2. 对每个文档分块 *)
let all_chunks =
  List.concat_map (fun doc ->
    let chunks = Chunking.chunk_recursive
      ~text:doc.Document.content ~max_size:1000 ~overlap:200 in
    List.map (fun c ->
      ({ Vector_store.id = Printf.sprintf "%s_%04d" doc.Document.source (Random.int 10000);
         content = c.Chunking.text;
         metadata = Some (Document.Meta.to_yojson doc.Document.metadata) },
       c.Chunking.text)  (* 将被实际向量替换 *)
    ) chunks
  ) docs
in

(* 3. 嵌入 chunks *)
let texts = List.map snd all_chunks in
match Runtime.embed rt texts with
| Error e ->
  prerr_endline ("embed failed: " ^ Runtime.string_of_error_category e)
| Ok vecs ->
  (* 4. 存入向量索引 *)
  let doc_vecs = List.mapi (fun i (doc, _) ->
    ({ doc with Vector_store.id = Printf.sprintf "doc_%04d" i }, vecs.(i))
  ) all_chunks in
  (match Vector_store.add store doc_vecs with
   | Ok () ->
     Printf.printf "Indexed %d chunks\n" (List.length doc_vecs);
     (* 5. 通过 RAG 查询 *)
     let (answer, _) = Runtime.invoke_with_rag rt
       ~agent_id:"rag_agent"
       ~message:"这个文档说了什么关于 X 的内容？"
       ~k:4
       ~vector_store:(Some store)
       () in
     Printf.printf "Answer: %s\n" answer
   | Error e ->
     prerr_endline ("store add failed: " ^ Runtime.string_of_error_category e))
```

要点：

- `Document.content` 作为 `~text` 参数传入 `Chunking.chunk_recursive`。
- `Document.Metadata.to_yojson` 将哈希表转换为 `Yojson.Safe.t`，用于 `Vector_store.document.metadata`。
- 每个 `Document.t` 的 `source` 字段成为向量存储文档 id 的基础。
- 加载和分块步骤与 embedding provider 无关。将 Mock 替换为 OpenAI 只需修改运行时配置。

## 错误处理

所有加载器返回 `(unit -> Document.t list, load_error) result`。模式如下：

```ocaml
match My_loader.make ws path with
| Error e ->
  (* 处理错误：文件不存在、权限不足等 *)
  prerr_endline (Document.load_error_to_string e)
| Ok load ->
  let docs = load () in
  (* 处理文档 *)
  ...
```

两步模式（make 返回 thunk，调用 thunk 产出文档）将路径验证与 I/O 分离。如果路径无效，会立即收到错误而不读取任何文件。提取过程中的异常会被捕获并记录日志（thunk 返回空列表而非崩溃）。

对于 `Directory_loader`，单个文件的错误会被记录并跳过，而不是中止整个扫描。这是有意的设计：知识库中一个损坏的 PDF 不应该阻止旁边的 Markdown 文件被索引。

## 另请参阅

- [RAG API](rag.md) — embeddings、向量存储、分块、`invoke_with_rag`
- [Streaming API](streaming.md) — `invoke_stream`、token 流式输出
- [Agent API](agent.md) — `Runtime.invoke`、agent 配置
- [SDK 概览](overview.md) — 模块映射与架构
