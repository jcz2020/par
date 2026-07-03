<!-- language: en -->

**English** · [简体中文](../zh/sdk/content_blocks.md)

# Content Blocks

Messages in PAR carry structured content through `content_block list` rather than flat strings. When you call `Runtime.invoke`, the response message contains a list of these blocks — text, tool calls, tool results, or images. Each block in the list can independently hold a `cache_control` field, which provider adapters (`` `Anthropic ``, `` `Openai ``) emit in the wire format for prompt caching.

The `message` type in `Types` looks like this:

```ocaml
type message = {
  role : message_role;
  content_blocks : content_block list;
  tool_calls : tool_call list option;
  tool_call_id : string option;
  name : string option;
}
```

`content_blocks` replaced the old `content : string option` field. Every block is a variant of `content_block`, each with its own `cache_control` slot.

## Block types

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

**Text_block** holds plain text. The LLM's response text and user input both land here.

**Tool_use_block** represents an LLM's request to call a tool. The `id` matches the provider's tool-use identifier; `name` is the tool name; `arguments` is the JSON payload.

**Tool_result_block** carries the tool handler's output back to the conversation. `tool_use_id` links it to the originating `Tool_use_block`.

**Image_block** holds image data, either as a URL reference or base64-encoded bytes. `media_type` is the MIME type (e.g. `"image/png"`).

## Construction

Build each variant by hand with record syntax:

```ocaml
(* Simple text block *)
let block = Text_block {
  text = "Hello, world!";
  cache_control = None;
}

(* Text block with prompt caching *)
let cached = Text_block {
  text = "System prompt content";
  cache_control = Some { type_ = `Ephemeral; ttl = Some `Five_min };
}

(* Tool result from a handler *)
let result = Tool_result_block {
  tool_use_id = "call_abc123";
  content = "42";
  cache_control = None;
}

(* Tool use from LLM response *)
let tool_use = Tool_use_block {
  id = "call_abc123";
  name = "calculator";
  arguments = `Assoc [("expression", `String "6 * 7")];
  cache_control = None;
}

(* Image from URL *)
let img = Image_block {
  source = Url "https://example.com/photo.png";
  media_type = "image/png";
  data = "";
  cache_control = None;
}

(* Image from base64 *)
let img_b64 = Image_block {
  source = Base64 "iVBORw0KGgo...";
  media_type = "image/png";
  data = "";
  cache_control = None;
}
```

Build a full message by populating the record:

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

## Helper functions

The `Message` module provides three helpers for common string-to-block conversions.

### content_of_string

```ocaml
val Message.content_of_string : string -> content_block list
```

Wraps a string in a single `Text_block` with `cache_control = None`. Returns an empty list for the empty string.

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

Extracts text from all `Text_block` and `Tool_result_block` variants and concatenates them. Non-text blocks (`Tool_use_block`, `Image_block`) are silently skipped.

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

Convenience wrapper. Equivalent to `Message.string_of_content msg.content_blocks`.

```ocaml
Message.text_of_message msg
(* Extracts all text and tool-result content from the message *)
```

### content_opt

```ocaml
val Message.content_opt : Types.message -> string option
```

Returns `Some text` if the message has any extractable text, or `None` if the content is empty. Useful for pattern matching on responses.

```ocaml
match Message.content_opt resp with
| Some text -> Printf.printf "Got: %s\n" text
| None -> Printf.printf "No text in response\n"
```

## cache_control

Every block variant carries an optional `cache_control` field:

```ocaml
type cache_control = {
  type_ : [`Ephemeral];
  ttl : cache_ttl option;
}

type cache_ttl = [`Five_min | `One_hour]
```

`type_` is currently always `` `Ephemeral ``. The type is a variant, not a plain alias, so PAR can introduce persistent cache modes later without breaking changes. `ttl` is the time-to-live hint. The Anthropic wire format recognizes both values; other providers ignore `cache_control` gracefully.

### Setting cache_control

There are three ways to mark blocks for caching.

**Direct construction.** Build the `cache_control` value inline:

```ocaml
Text_block {
  text = "Expensive system prompt";
  cache_control = Some { type_ = `Ephemeral; ttl = Some `Five_min };
}
```

**Cache_breakpoint.mark_message.** Marks the *last* block in a message's `content_blocks` list. This is the recommended user-facing API for caching a whole message:

```ocaml
val Cache_breakpoint.mark_message :
  ttl:Types.cache_ttl ->
  Types.message ->
  Types.message
```

```ocaml
let marked_msg = Cache_breakpoint.mark_message ~ttl:`One_hour msg
(* The last block in msg.content_blocks now has cache_control set *)
```

The function walks to the last block and applies `cache_control` to it regardless of variant. If `content_blocks` is empty, it's a no-op.

**Engine auto-marking.** The Engine calls `apply_breakpoints` internally before each LLM round trip. It evaluates breakpoint candidates (system prompt, per-message, per-tool) against the provider's cache capabilities, then stamps the chosen blocks automatically. You don't need to call this yourself; it runs as part of the ReAct loop.

### Provider support

Prompt caching is currently supported by the `` `Anthropic `` wire format. When the provider adapter encounters a block with `cache_control` set, it emits the corresponding field in the JSON payload. The `` `Openai `` and `` `Ollama `` adapters ignore `cache_control` silently, so setting it on those providers is harmless.

## Image blocks

```ocaml
type image_source =
  | Url of string
  | Base64 of string
```

`Image_block` carries a reference to image data along with its MIME type. `Url` points to an image hosted at a remote URL; the provider fetches it. `Base64` embeds the raw bytes directly in the block.

Image blocks are part of PAR's type-level preparation for multimodal content. The Anthropic wire format already supports image blocks natively. User-facing image tools and higher-level APIs are planned for v0.7.

## Migration from string

The old `message` type had `content : string option`. The new type, used by `Runtime.create` and all agent interactions, replaces this with `content_blocks : content_block list`. Here's how to migrate:

```ocaml
(* Old pattern *)
let msg = {
  role = User;
  content = Some "hello";
  tool_calls = None;
  tool_call_id = None;
  name = None;
}

(* New pattern *)
let msg = {
  role = User;
  content_blocks = Message.content_of_string "hello";
  tool_calls = None;
  tool_call_id = None;
  name = None;
}
```

For multi-block content, build the list explicitly:

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

Reading content back out works through the same helpers, so code that previously used `msg.content` directly should switch to `Message.text_of_message msg` or `Message.content_opt msg`.

## See also

- [Agent API](agent.md) -- Runtime configuration, agent config, tool registration
- [Streaming API](streaming.md) -- Token streaming with content block events
- [Middleware API](middleware.md) -- Pipeline hooks that see content blocks
