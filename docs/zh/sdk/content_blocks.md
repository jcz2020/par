<!-- language: zh -->
**[English](../sdk/content_blocks.md)** · 简体中文

# 内容块

PAR 中的消息通过 `content_block list` 携带结构化内容，而非扁平字符串。当你调用 `Runtime.invoke` 时，响应消息包含这些块的列表——文本、工具调用、工具结果或图像。列表中的每个块都可以独立持有 `cache_control` 字段，provider 适配器（`` `Anthropic ``、`` `Openai ``）在线路格式中发出该字段用于 prompt 缓存。

`Types` 中的 `message` 类型如下：

```ocaml
type message = {
  role : message_role;
  content_blocks : content_block list;
  tool_calls : tool_call list option;
  tool_call_id : string option;
  name : string option;
}
```

`content_blocks` 替代了旧的 `content : string option` 字段。每个块是 `content_block` 的一个变体，各有自己的 `cache_control` 槽位。

## 块类型

```ocaml
type content_block =
  | Text_block of {
      text : string;
      cache_control : cache_control option;
    }
  | Tool_use_block of {
      id : string;
      name : string;
      arguments : Yojson.Safe.t;
      cache_control : cache_control option;
    }
  | Tool_result_block of {
      tool_use_id : string;
      content : string;
      cache_control : cache_control option;
    }
  | Image_block of {
      source : image_source;
      media_type : string;
      data : string;
      cache_control : cache_control option;
    }
```

**Text_block** 持有纯文本。LLM 的响应文本和用户输入都落在这里。

**Tool_use_block** 表示 LLM 请求调用工具。`id` 匹配 provider 的工具使用标识符；`name` 是工具名称；`arguments` 是 JSON 负载。

**Tool_result_block** 将工具处理器的输出携带回对话。`tool_use_id` 将其链接到发起的 `Tool_use_block`。

**Image_block** 持有图像数据，可以是 URL 引用或 base64 编码的字节。`media_type` 是 MIME 类型（如 `"image/png"`）。

## 构造

用记录语法手动构造每个变体：

```ocaml
(* 简单文本块 *)
let block = Text_block {
  text = "Hello, world!";
  cache_control = None;
}

(* 带 prompt 缓存的文本块 *)
let cached = Text_block {
  text = "System prompt content";
  cache_control = Some { type_ = `Ephemeral; ttl = Some `Five_min };
}

(* 来自处理器的工具结果 *)
let result = Tool_result_block {
  tool_use_id = "call_abc123";
  content = "42";
  cache_control = None;
}

(* 来自 LLM 响应的工具使用 *)
let tool_use = Tool_use_block {
  id = "call_abc123";
  name = "calculator";
  arguments = `Assoc [("expression", `String "6 * 7")];
  cache_control = None;
}

(* 来自 URL 的图像 *)
let img = Image_block {
  source = Url "https://example.com/photo.png";
  media_type = "image/png";
  data = "";
  cache_control = None;
}

(* 来自 base64 的图像 *)
let img_b64 = Image_block {
  source = Base64 "iVBORw0KGgo...";
  media_type = "image/png";
  data = "";
  cache_control = None;
}
```

通过填充记录来构建完整消息：

```ocaml
let msg : Types.message = {
  role = User;
  content_blocks = [
    Text_block { text = "What is 2+2?"; cache_control = None };
  ];
  tool_calls = None;
  tool_call_id = None;
  name = None;
}
```

## 辅助函数

`Message` 模块提供三个辅助函数用于常见的字符串到块的转换。

### content_of_string

```ocaml
val Message.content_of_string : string -> content_block list
```

将字符串包装在单个 `Text_block` 中，`cache_control = None`。空字符串返回空列表。

```ocaml
Message.content_of_string "Hello"
(* [Text_block { text = "Hello"; cache_control = None }] *)

Message.content_of_string ""
(* [] *)
```

### string_of_content

```ocaml
val Message.string_of_content : content_block list -> string
```

从所有 `Text_block` 和 `Tool_result_block` 变体中提取文本并连接它们。非文本块（`Tool_use_block`、`Image_block`）被静默跳过。

```ocaml
Message.string_of_content [
  Text_block { text = "Hello "; cache_control = None };
  Tool_use_block { id = "x"; name = "t"; arguments = `Assoc []; cache_control = None };
  Text_block { text = "world"; cache_control = None };
]
(* "Hello world" *)
```

### text_of_message

```ocaml
val Message.text_of_message : Types.message -> string
```

便捷包装器。等价于 `Message.string_of_content msg.content_blocks`。

```ocaml
Message.text_of_message msg
(* 提取消息中的所有文本和工具结果内容 *)
```

### content_opt

```ocaml
val Message.content_opt : Types.message -> string option
```

如果消息有可提取的文本则返回 `Some text`，内容为空则返回 `None`。用于对响应进行模式匹配。

```ocaml
match Message.content_opt resp with
| Some text -> Printf.printf "Got: %s\n" text
| None -> Printf.printf "No text in response\n"
```

## cache_control

每个块变体都携带一个可选的 `cache_control` 字段：

```ocaml
type cache_control = {
  type_ : [`Ephemeral];
  ttl : cache_ttl option;
}

type cache_ttl = [`Five_min | `One_hour]
```

`type_` 目前始终是 `` `Ephemeral ``。该类型是变体而非简单别名，因此 PAR 可以在不破坏性变更的情况下引入持久缓存模式。`ttl` 是存活时间提示。`` `Anthropic `` 线路格式识别这两个值；其他 provider 优雅地忽略 `cache_control`。

### 设置 cache_control

有三种方式标记块用于缓存。

**直接构造。** 内联构建 `cache_control` 值：

```ocaml
Text_block {
  text = "Expensive system prompt";
  cache_control = Some { type_ = `Ephemeral; ttl = Some `Five_min };
}
```

**Cache_breakpoint.mark_message。** 标记消息 `content_blocks` 列表中的*最后*一个块。这是缓存整个消息的推荐面向用户的 API：

```ocaml
val Cache_breakpoint.mark_message :
  ttl:Types.cache_ttl ->
  Types.message ->
  Types.message
```

```ocaml
let marked_msg = Cache_breakpoint.mark_message ~ttl:`One_hour msg
(* msg.content_blocks 中的最后一个块现在设置了 cache_control *)
```

该函数遍历到最后一个块并对其应用 `cache_control`，无论变体类型。如果 `content_blocks` 为空，则为空操作。

**Engine 自动标记。** Engine 在每次 LLM 往返前内部调用 `apply_breakpoints`。它根据 provider 的缓存能力评估断点候选（系统提示、每条消息、每个工具），然后自动标记选定的块。你不需要自己调用它；它作为 ReAct 循环的一部分运行。

### Provider 支持

Prompt 缓存目前由 `` `Anthropic `` 线路格式支持。当 provider 适配器遇到设置了 `cache_control` 的块时，它在 JSON 负载中发出相应字段。`` `Openai `` 和 `` `Ollama `` 适配器静默忽略 `cache_control`，所以在这些 provider 上设置它是无害的。

## 图像块

```ocaml
type image_source =
  | Url of string
  | Base64 of string
```

`Image_block` 携带对图像数据的引用及其 MIME 类型。`Url` 指向远程 URL 托管的图像；provider 获取它。`Base64` 直接在块中嵌入原始字节。

图像是 PAR 为多模态内容做的类型级准备的一部分。`` `Anthropic `` 线路格式已经原生支持图像块。面向用户的图像工具和更高级的 API 计划在 v0.7 中推出。

## 从 string 迁移

旧的 `message` 类型有 `content : string option`。新的类型用 `content_blocks : content_block list` 替代。迁移方法：

```ocaml
(* 旧模式 *)
let msg = {
  role = User;
  content = Some "hello";
  tool_calls = None;
  tool_call_id = None;
  name = None;
}

(* 新模式 *)
let msg = {
  role = User;
  content_blocks = Message.content_of_string "hello";
  tool_calls = None;
  tool_call_id = None;
  name = None;
}
```

对于多块内容，显式构建列表：

```ocaml
let msg = {
  role = User;
  content_blocks = [
    Text_block { text = "Describe this image:"; cache_control = None };
    Image_block {
      source = Url "https://example.com/photo.png";
      media_type = "image/png";
      data = "";
      cache_control = None;
    };
  ];
  tool_calls = None;
  tool_call_id = None;
  name = None;
}
```

读回内容通过相同的辅助函数工作，所以之前直接使用 `msg.content` 的代码应该切换到 `Message.text_of_message msg` 或 `Message.content_opt msg`。

## 另请参阅

- [Agent API](agent.md) — Runtime 配置、agent 配置、工具注册
- [Streaming API](streaming.md) — 带内容块事件的 token 流式传输
- [中间件 API](middleware.md) — 看到内容块的管道钩子
