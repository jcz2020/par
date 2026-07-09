<!-- language: en -->
**English** · [简体中文](../zh/sdk/document_loaders.md)

# Document Loaders

> Added in v0.7.0 (beta). Source-of-truth: the OCaml types in `lib/documents/document.mli`, `lib/documents/*_loader.mli`, and `lib/documents/directory_loader.mli`.

PAR's document loaders turn real files (text, Markdown, HTML, CSV, PDF) into `Document.t` records that plug directly into the RAG pipeline. Load a PDF, chunk it with `Chunking`, embed the chunks with `Runtime.embed`, store them in a `Vector_store`, and query with `Runtime.invoke_with_rag`. The loaders handle file I/O, format parsing, and metadata extraction so you don't have to.

For the full RAG pipeline (embeddings, vector store, chunking, retrieval), see the [RAG API](rag.md). Document loaders produce the `Document.t` values that feed into that pipeline.

## The Document type

A loaded document is a record with three fields:

```ocaml
type t = {
  content : string;    (** extracted plain text *)
  metadata : (string, Yojson.Safe.t) Hashtbl.t;  (** source-derived fields *)
  source : string;     (** file path or URI *)
}
```

The `content` field is the extracted plain text. The `source` field is the original file path or URI. The `metadata` hashtable carries whatever the loader knows about the source: file name, file size, page number, column values, YAML frontmatter, and so on.

The `metadata` type is `(string, Yojson.Safe.t) Hashtbl.t`, matching the metadata field on `Vector_store.document`. This means loader output passes to `Vector_store.add` without conversion.

### Metadata helpers

The `Meta` submodule provides convenience constructors:

```ocaml
open Par.Document.Meta

let m = empty ()                          (* fresh empty table *)
let m = singleton "source" (`String "a.md")  (* one-entry table *)
add m "page" (`Int 3)                     (* add a Yojson value *)
add_string m "file_type" "text/markdown"   (* shorthand for `String *)
add_int m "file_size" 4096                (* shorthand for `Int *)

(* Round-trip to/from Yojson *)
let json = to_yojson m in
let m' = of_yojson json
```

### Load errors

When a loader fails, it returns a `Load_error.t` variant:

| Variant | Meaning |
|---------|---------|
| `File_not_found of string` | The file does not exist at the given path |
| `Permission_denied of string` | The file exists but cannot be read |
| `Unsupported_format of string` | The loader does not handle this file type |
| `Extraction_failed of string * string` | Parsing or extraction failed (message, exception printout) |
| `Workspace_rejected of Types.error_category` | The path was rejected by `Workspace.admit` (security check) |

Use `Document.load_error_to_string` to get a human-readable message:

```ocaml
let print_error err =
  prerr_endline (Document.load_error_to_string err)
```

## The LOADER contract

Every format loader satisfies the `LOADER` module type:

```ocaml
module type LOADER = sig
  val lazy_load : unit -> Document.t Seq.t   (** canonical; override this *)
  val load : unit -> Document.t list          (** default = List.of_seq (lazy_load ()) *)
end
```

`lazy_load` is the canonical entry point. It returns a lazy sequence, which matters for large directories where you don't want all documents in memory at once. `load` has a default implementation that materializes the sequence into a list.

### Implementing a custom loader

To add support for a new file format, write a module that satisfies the loader constructor pattern. Every built-in loader follows this shape:

```ocaml
module My_loader : sig
  val make : Workspace.workspace -> string ->
    (unit -> Document.t list, Document.load_error) result
end
```

`make` takes a workspace (for path security validation) and a file path. On success it returns a thunk that, when called, reads the file and produces `Document.t list`. On failure it returns a `load_error`.

Here's a minimal custom loader:

```ocaml
open Par

let make ws path =
  match Workspace.admit ws path with
  | Error e -> Error (Workspace_rejected e)
  | Ok () ->
    Ok (fun () ->
      let ic = open_in path in
      let content = really_input_string ic (in_channel_length ic) in
      close_in ic;
      let meta = Document.Meta.empty () in
      Document.Meta.add_string meta "file_type" "application/x-myformat";
      [{ Document.content; metadata = meta; source = path }])
```

## Built-in loaders

PAR ships five format loaders. Each one produces `Document.t list` from a single file.

### Text_loader (.txt)

Reads a plain text file and produces one `Document.t` with standard metadata.

```ocaml
open Par

let ws = Workspace.of_cwd () in
match Text_loader.make ws "notes.txt" with
| Error e -> prerr_endline (Document.load_error_to_string e)
| Ok load ->
  let docs = load () in
  Printf.printf "Loaded %d document(s)\n" (List.length docs)
```

**Metadata fields:** `file_path`, `file_name`, `file_size`, `file_type = "text/plain"`.

### Markdown_loader (.md)

Parses Markdown via `Omd.of_string` and walks the AST to extract plain text (headings, paragraphs, code blocks, lists). YAML frontmatter (between `---` delimiters at file start) is parsed via `Yaml.of_string` and merged into the metadata alongside the standard fields.

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

**Metadata fields:** `file_path`, `file_name`, `file_size`, `file_type = "text/markdown"`, plus any YAML frontmatter keys.

### Html_loader (.html)

Reads an HTML file, strips `<script>` and `<style>` elements, and extracts the visible text content via lambdasoup.

```ocaml
open Par

let ws = Workspace.of_cwd () in
match Html_loader.make ws "page.html" with
| Error e -> prerr_endline (Document.load_error_to_string e)
| Ok load ->
  let docs = load () in
  Printf.printf "Extracted %d document(s)\n" (List.length docs)
```

**Metadata fields:** `file_path`, `file_name`, `file_size`, `file_type = "text/html"`.

### Csv_loader (.csv)

Reads a CSV file. The header row defines column names. Each data row (excluding the header) produces one `Document.t`:

- `content`: key-value lines formatted as `"column_name: value\n"` for each column.
- `metadata`: each column name mapped to its value (as `String`), plus `row_index`, `file_path`, `file_name`, `file_size`, `file_type = "text/csv"`.
- `source`: the input file path.

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

Extracts text from a PDF using camlpdf's simple text-stream extraction. Each page produces one `Document.t` with `metadata["page"]` set to the page number.

```ocaml
open Par

let ws = Workspace.of_cwd () in
match Pdf_loader.make ws "paper.pdf" with
| Error e -> prerr_endline (Document.load_error_to_string e)
| Ok load ->
  let docs = load () in
  Printf.printf "Extracted %d pages\n" (List.length docs)
```

**Metadata fields:** `file_path`, `file_name`, `file_size`, `file_type = "application/pdf"`, `page` (int, 1-indexed).

#### Limitations

!!! warning "Scope compromise — see ROADMAP v0.7.0 section 2 #9"

    The PDF loader uses simple text-stream extraction, **not** layout-preserving extraction. This is a deliberate scope compromise with a retirement plan.

    - **No layout preservation:** Multi-column PDFs produce interleaved text. The columns get mixed together in the output.
    - **No OCR:** Scanned or image-only PDFs extract nothing. There is no Tesseract or OCR engine behind this loader.
    - **Tables and complex layouts** may produce poor output.

    This covers roughly 80% of text-type PDFs (research papers, documentation, reports with single-column or simple layouts).

    **Trigger for layout-aware extraction:** If downstream integration reports a failure rate greater than 20%, or when v0.8 planning begins, whichever comes first. The migration path is to replace the internals of `Pdf_loader.extract_text` without changing the public interface, since the `Document.t -> Document.t` contract stays the same.

    **.docx (Word) support** is deferred to v0.7.1. There is no maintained OCaml library for Word documents, and a DIY implementation would be fragile. See ROADMAP v0.7.0 section 4 for the full deferral rationale.

## Directory_loader

The directory loader recursively scans a directory tree and dispatches each file to the appropriate format loader based on its extension.

```ocaml
open Par

let ws = Workspace.of_cwd () in
match Directory_loader.load ws ~map:Directory_loader.default_map "docs/" with
| Error e -> prerr_endline (Document.load_error_to_string e)
| Ok docs ->
  Printf.printf "Loaded %d documents from directory\n" (List.length docs)
```

**`default_map`** covers `.txt`, `.md`, `.html`, `.csv`, and `.pdf`. Unknown extensions are skipped with a `Logs.warn`. Errors in individual files are logged and skipped (the scan does not abort).

### Custom extension map

You can override or extend the extension map:

```ocaml
open Par

(* Add a custom loader for .json files *)
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

The `loader_fn` type is `Workspace.workspace -> string -> (unit -> Document.t list, Document.load_error) result`, matching the signature of every built-in loader's `make` function.

## Composition with RAG

The full pipeline: load documents, chunk them, embed the chunks, store the vectors, and query with `invoke_with_rag`.

```ocaml
open Par
open Types

let ws = Workspace.of_cwd () in

(* 1. Load documents from a directory *)
let docs = Directory_loader.load ws ~map:Directory_loader.default_map "knowledge_base/"
  |> Result.get_ok in

(* 2. Chunk each document *)
let all_chunks =
  List.concat_map (fun doc ->
    let chunks = Chunking.chunk_recursive
      ~text:doc.Document.content ~max_size:1000 ~overlap:200 in
    List.map (fun c ->
      ({ Vector_store.id = Printf.sprintf "%s_%04d" doc.Document.source (Random.int 10000);
         content = c.Chunking.text;
         metadata = Some (Document.Meta.to_yojson doc.Document.metadata) },
       c.Chunking.text)  (* will be replaced by actual vectors *)
    ) chunks
  ) docs
in

(* 3. Embed the chunks *)
let texts = List.map snd all_chunks in
match Runtime.embed rt texts with
| Error e ->
  prerr_endline ("embed failed: " ^ Runtime.string_of_error_category e)
| Ok vecs ->
  (* 4. Store in vector index *)
  let doc_vecs = List.mapi (fun i (doc, _) ->
    ({ doc with Vector_store.id = Printf.sprintf "doc_%04d" i }, vecs.(i))
  ) all_chunks in
  (match Vector_store.add store doc_vecs with
   | Ok () ->
     Printf.printf "Indexed %d chunks\n" (List.length doc_vecs);
     (* 5. Query with RAG *)
     let (answer, _) = Runtime.invoke_with_rag rt
       ~agent_id:"rag_agent"
       ~message:"What does this document say about X?"
       ~k:4
       ~vector_store:(Some store)
       () in
     Printf.printf "Answer: %s\n" answer
   | Error e ->
     prerr_endline ("store add failed: " ^ Runtime.string_of_error_category e))
```

Key points:

- `Document.content` feeds into `Chunking.chunk_recursive` as the `~text` parameter.
- `Document.Metadata.to_yojson` converts the hashtable to `Yojson.Safe.t` for `Vector_store.document.metadata`.
- The `source` field on each `Document.t` becomes the basis for the vector store document id.
- The loader and chunking steps are independent of the embedding provider. Swap Mock for OpenAI by changing the runtime config.

## Error handling

All loaders return `(unit -> Document.t list, load_error) result`. The pattern is:

```ocaml
match My_loader.make ws path with
| Error e ->
  (* Handle the error: file not found, permission denied, etc. *)
  prerr_endline (Document.load_error_to_string e)
| Ok load ->
  let docs = load () in
  (* Process documents *)
  ...
```

The two-step pattern (make returns a thunk, calling the thunk produces documents) separates path validation from I/O. If the path is invalid, you get an error immediately without reading any file. If the file exists but extraction fails, the error comes from calling the thunk.

For `Directory_loader`, individual file errors are logged and skipped rather than aborting the entire scan. This is intentional: you want a corrupt PDF in your knowledge base to not prevent the Markdown files next to it from being indexed.

## See also

- [RAG API](rag.md) — embeddings, vector store, chunking, `invoke_with_rag`
- [Streaming API](streaming.md) — `invoke_stream`, token streaming
- [Agent API](agent.md) — `Runtime.invoke`, agent configuration
- [SDK overview](overview.md) — module map and architecture
