<!-- language: en -->

**English** · [简体中文](../zh-CN/sdk/mcp.md)

> Translated to English for v0.3.2. Source-of-truth: the OCaml modules in lib/mcp/.

# MCP Client API Reference

This document describes the P-A-R SDK's MCP (Model Context Protocol) client (stdio + HTTP/SSE). A PAR agent can connect to any MCP server (filesystem, git, sqlite, github, etc.) and consume the tools, resources, and prompts it exposes.

**Version**: v0.3.1
**Transports**: stdio + HTTP/SSE (Streamable HTTP, spec 2025-06-18)

## Overview

MCP is the LLM tool integration protocol proposed by Anthropic. The server side exposes tools, data resources, and prompt templates over stdio as JSON-RPC 2.0. PAR v0.3.1 implements the client side, so any PAR agent can transparently call any server that follows the MCP specification.

Why stdio first: local process communication removes network dependencies, TLS configuration, and reverse-proxy burden, and covers 90% of existing MCP server scenarios.

### Three public modules

Available after `open Par`:

| Module | Responsibility |
|------|------|
| `Par.Mcp_types` | Protocol types: config, capabilities, tool/resource/prompt records, JSON-RPC types |
| `Par.Mcp_server` | Low-level server lifecycle: spawn, stop, call_method, notify |
| `Par.Mcp_client` | High-level typed API: connect, list_tools, call_tool, read_resource, get_prompt |

Most users only need `Mcp_client`. Reach for `Mcp_server` when you need to manage the lifecycle yourself (for example, dynamic add/remove of servers). Transports live in `Mcp_transport_stdio` (local process) and `Mcp_transport_http` (remote HTTP/SSE); server name validation in `Mcp_naming`; error mapping in `Mcp_errors`.

### v0.3.1 scope

| Capability | Status |
|------|------|
| stdio transport | done |
| initialize / initialized handshake | done |
| tools/list, tools/call | done |
| resources/list, resources/read | done |
| prompts/list, prompts/get | done |
| ping | done |
| notifications (list_changed, progress, cancelled) | done |
| Startup policy: fail-fast / log-and-continue | done |
| Graceful shutdown (SIGTERM then SIGKILL fallback) | done |
| HTTP / SSE transport | done (v0.4.3) |
| sampling (server to LLM reverse call) | not implemented |
| roots / elicitation | not implemented |

---

## Quick Start

Minimal example: connect an `npx`-style MCP filesystem server.

```ocaml
open Par

let config = {
  persistence = `Sqlite ":memory:";
  event_bus = Runtime.default_event_bus_config;
  default_quota = Runtime.default_quota;
  shutdown = Runtime.default_shutdown_config;
  llm_providers = [];
  eval_limits = { max_depth = 10; max_node_visits = 1000 };
}

let mcp_fs_config : Mcp_types.server_config = {
  name = "fs";
  command = "npx";
  args = [ "-y"; "@modelcontextprotocol/server-filesystem"; "/tmp" ];
  env = [];
  cwd = None;
  startup_timeout = 10.0;
}

let () = Eio_main.run (fun env ->
  Eio.Switch.run (fun sw ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clock = Eio.Stdenv.clock env in
    match
      Runtime.create
        ~mcp_servers:[mcp_fs_config]
        ~mcp_process_mgr:mgr
        ~mcp_clock:clock
        ~config sw
    with
    | Error e ->
      Printf.eprintf "Runtime create failed: %a\n"
        Yojson.Safe.pp (Types.error_category_to_yojson e)
    | Ok rt ->
      (* Pull the client handle by server_id *)
      (match Runtime.mcp_server rt (Mcp_types.server_id_of_string "fs" |> Result.get_ok) with
       | Error _ -> Printf.eprintf "Server not found\n"
       | Ok _client -> ());
      ignore (Runtime.close rt)
  )
)
```

`Runtime.create` internally spawns a child process for every configured server, runs the initialize handshake, and only returns `Ok rt` once every server has reached the `Ready` state (under the fail-fast policy).

---

## Runtime Integration

### Construction parameters

```ocaml
val Runtime.create :
  ?persistence:persistence_service ->
  ?event_bus:Types.event_bus_service ->
  ?llm:llm_service ->
  ?bash_policy:(module Bash_policy.POLICY) ->
  ?mcp_servers:Mcp_types.server_config list ->
  ?mcp_process_mgr:_ Eio.Process.mgr ->
  ?mcp_clock:_ Eio.Time.clock ->
  ?mcp_startup_policy:Mcp_types.startup_policy ->
  config:runtime_config ->
  Eio.Switch.t ->
  (runtime, error_category) result
```

MCP-related parameters:

| Parameter | Type | Default | Required when |
|------|------|------|----------|
| `?mcp_servers` | `server_config list` | `[]` | no |
| `?mcp_process_mgr` | `Eio.Process.mgr` | none | required if `mcp_servers` is non-empty |
| `?mcp_clock` | `Eio.Time.clock` | none | required if `mcp_servers` is non-empty |
| `?mcp_startup_policy` | `startup_policy` | `Fail_fast` | no |

The idiomatic call pulls the Eio environment once and threads it through.

```ocaml
Eio_main.run (fun env ->
  Eio.Switch.run (fun sw ->
    let mgr = Eio.Stdenv.process_mgr env in
    let clock = Eio.Stdenv.clock env in
    let rt = Runtime.create
      ~mcp_servers:[fs_cfg; git_cfg]
      ~mcp_process_mgr:mgr
      ~mcp_clock:clock
      ~mcp_startup_policy:Mcp_types.Log_and_continue
      ~config sw
      |> Result.get_ok
    in
    ...
  )
)
```

### Startup policy

```ocaml
type startup_policy =
  | Fail_fast          (* Any server failing to start returns Error immediately *)
  | Log_and_continue   (* Failed servers are reported on the event bus; the rest keep running *)
```

- **`Fail_fast`** (default): right for production, where every server must be available.
- **`Log_and_continue`**: right for development or optional capabilities (a linter server, for example). Detect failures through the `Mcp_server_failed` event.

### Shutdown

`Runtime.close` is the master switch: it closes every MCP server first, then the event bus and persistence layer. Each server emits one `Mcp_server_stopped` event as it shuts down.

```ocaml
let _exit_code = Runtime.close rt
```

You do not need to call `Mcp_client.disconnect` or `Mcp_server.stop` manually. `Runtime.close` owns every derived resource.

### Accessing the server table

```ocaml
`Runtime.mcp_servers` returns the set of servers the runtime currently holds (a `server_id → server` map). `Runtime.mcp_server` looks up a single server by id.

The `server_id` defaults to the `server_config.name` field. Duplicate names get an automatic suffix (`-1`, `-2`, and so on), implemented by `server_id_with_suffix`. `server_id_compare` is used for sorting.

```ocaml
(* Look up by id *)
let sid = Mcp_types.server_id_of_string "fs" |> Result.get_ok in
match Runtime.mcp_server rt sid with
| Ok srv -> Mcp_server.status srv
| Error _ -> ...
```

Server name validation is centralized in `Mcp_naming.validate_server_name`; the rules are: nonempty, at most 32 characters, and limited to `[a-zA-Z0-9_-]`.

---

## Mcp_client API

The high-level typed API. Most scenarios should use `Mcp_client` instead of touching `Mcp_server` directly: JSON parsing and `result` field extraction are hidden from you.

### Type

```ocaml
type t  (* Wraps a ready Mcp_server.t *)
```

### Connect and disconnect

```ocaml
val connect :
  sw:Eio.Switch.t ->
  process_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  Mcp_types.server_config ->
  (t, error_category) result

val disconnect : t -> (unit, error_category) result
```

`connect` is `Mcp_server.spawn` plus the client wrapper. `disconnect` delegates to `Mcp_server.stop` and is idempotent.

### Accessors

```ocaml
val id           : t -> Mcp_types.server_id
val name         : t -> string
val capabilities : t -> Mcp_types.capabilities
val status       : t -> Mcp_server.status
```

`status` returns `Starting | Ready of capabilities | Failed of error | Stopped`. In a healthy run it is always `Ready`.

### Tools

```ocaml
val list_tools : t -> (Mcp_types.mcp_tool list, error_category) result
val call_tool  : t -> name:string -> arguments:Yojson.Safe.t ->
                 (Yojson.Safe.t, error_category) result
```

`list_tools` returns the metadata of every tool the server has registered. The `arguments` to `call_tool` is the JSON input that the server's tool requires; the return value is also raw JSON, which the caller parses against `input_schema`.

```ocaml
let print_tools (client : Mcp_client.t) =
  match Mcp_client.list_tools client with
  | Error e ->
    Printf.eprintf "list_tools failed: %a\n"
      Yojson.Safe.pp (Types.error_category_to_yojson e)
  | Ok tools ->
    List.iter (fun t ->
      Printf.printf "- %s : %s\n"
        t.Mcp_types.name
        (Option.value t.Mcp_types.description ~default:""))
      tools

(* Invoke *)
let args = `Assoc [ ("path", `String "/tmp/hello.txt") ] in
match Mcp_client.call_tool client ~name:"read_file" ~arguments:args with
| Ok result -> print_endline (Yojson.Safe.to_string result)
| Error e -> ...
```

### Resources

```ocaml
val list_resources : t -> (Mcp_types.mcp_resource list, error_category) result
val read_resource  : t -> uri:string -> (Yojson.Safe.t, error_category) result
```

`read_resource` takes an MCP-style URI (`file://...`, `git://...`, and so on); the server parses it.

```ocaml
match Mcp_client.list_resources client with
| Ok resources ->
  List.iter (fun r ->
    Printf.printf "  %s (%s)\n" r.uri
      (Option.value r.mime_type ~default:"?"))
    resources
| Error _ -> ()

(* Read a resource *)
match Mcp_client.read_resource client ~uri:"file:///tmp/x.txt" with
| Ok body -> print_endline (Yojson.Safe.to_string body)
| Error _ -> ()
```

### Prompts

```ocaml
val list_prompts : t -> (Mcp_types.mcp_prompt list, error_category) result
val get_prompt  : t -> name:string -> ?arguments:(string * string) list -> unit ->
                  (Yojson.Safe.t, error_category) result
```

`get_prompt` returns the server-rendered prompt messages (as a JSON array). `?arguments` is a list of named parameters; when omitted, the server's defaults are used.

```ocaml
match Mcp_client.get_prompt client
        ~name:"commit_message"
        ~arguments:[("diff", "..."); ("style", "concise")] () with
| Ok rendered ->
  (* Usually a messages array *)
  print_endline (Yojson.Safe.pretty_to_string rendered)
| Error _ -> ()
```

### Utility

```ocaml
val ping : t -> (Yojson.Safe.t, error_category) result
```

Health check. Returns the server's `pong` response.

---

## Mcp_server Low-Level API

For scenarios that need to control the lifecycle manually: dynamic add/remove of servers, custom RPC methods, injecting extra notifications.

The stdio transport lives in `Mcp_transport_stdio`, which spawns the child process and wires stdin/stdout. The HTTP/SSE transport lives in `Mcp_transport_http` (v0.4.3), which connects to a remote MCP server over Streamable HTTP (spec 2025-06-18). `Mcp_server` sits one layer above both transports.

### Status

```ocaml
type status =
  | Starting
  | Ready of Mcp_types.capabilities
  | Failed of Types.error_category
  | Stopped
```

### Spawn

```ocaml
val spawn :
  sw:Eio.Switch.t ->
  process_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  Mcp_types.server_config ->
  (t, Types.error_category) result
```

- `sw`: parent switch; the child process lifetime is bound to it.
- `process_mgr`: used for `Eio.Process.spawn`.
- `clock`: used to enforce `startup_timeout`.
- `config`: see the configuration reference below.

After a successful spawn the initialize handshake has already completed; status is `Ready caps`.

### Accessors

```ocaml
val id           : t -> Mcp_types.server_id
val name         : t -> string
val pid          : t -> int
val capabilities : t -> Mcp_types.capabilities
val status       : t -> status
```

`pid` is the child process PID (POSIX), useful for correlating with `ps` output during operations.

### Generic RPC

```ocaml
val call_method :
  t -> method_:string -> params:Yojson.Safe.t ->
  (Yojson.Safe.t, Types.error_category) result

val notify :
  t -> method_:string -> params:Yojson.Safe.t ->
  (unit, Types.error_category) result
```

`call_method` sends a JSON-RPC request and blocks waiting for the response. `notify` sends a notification (no id, the server does not reply).

Most scenarios should use `Mcp_client`'s typed methods. `call_method` is for:

- Calling methods that exist in the MCP specification but are not yet covered by `Mcp_client` (custom extensions, for example)
- Early experimentation when implementing a newer MCP protocol version

### Stop

```ocaml
val stop : t -> (unit, Types.error_category) result
```

Shutdown timing: first send a `shutdown` request, wait 2 seconds for a graceful exit, send SIGTERM to the process group (`killpg`) if it has not exited, wait another 2 seconds, and finally SIGKILL. The function is idempotent; calling it more than once is safe.

`Runtime.close` calls `stop` on every server internally.

---

## Event Types

Seven new events, added to the `Par.Types.event` variant. All events flow out of the event bus and can be observed through `Runtime.subscribe`.

| Event | When it fires | Key fields |
|------|----------|----------|
| `Mcp_server_started` | server initialize succeeded | `server_id`, `server_name` |
| `Mcp_server_failed` | spawn failed, handshake failed, or the process crashed | `server_id`, `error` |
| `Mcp_server_stopped` | `Runtime.close` or explicit `disconnect` completed | `server_id` |
| `Mcp_tool_invoked` | entry of `call_tool` | `server_id`, `tool_name` |
| `Mcp_tool_completed` | exit of `call_tool` | `server_id`, `tool_name`, `duration_ms` |
| `Mcp_resource_read` | `read_resource` succeeded | `server_id`, `uri` |
| `Mcp_prompt_rendered` | `get_prompt` succeeded | `server_id`, `prompt_name` |

### Subscription example

```ocaml
open Par

let log_mcp_event (ev : Types.event) =
  match ev with
  | Mcp_server_started { server_id; server_name } ->
    Printf.printf "[mcp] started %s (%s)\n" server_id server_name
  | Mcp_server_failed { server_id; error } ->
    Printf.eprintf "[mcp] failed %s: %a\n"
      server_id Yojson.Safe.pp (Types.error_category_to_yojson error)
  | Mcp_tool_invoked { server_id; tool_name } ->
    Printf.printf "[mcp] call %s/%s\n" server_id tool_name
  | Mcp_tool_completed { server_id; tool_name; duration_ms } ->
    Printf.printf "[mcp] done  %s/%s in %.1fms\n"
      server_id tool_name duration_ms
  | _ -> ()

(* In the main loop *)
(* Event subscription: pass ?on_tool_event:(event -> unit) callback to Runtime.create *)
Event_bus.subscribe bus log_mcp_event
```

### Error events

The `error` field of `Mcp_server_failed` is a `Types.error_category`. Common values:

- `External_failure "spawn: ..."` : the child process failed to launch (executable missing)
- `Timeout "startup handshake"` : the initialize handshake timed out (the server had not replied to `initialize` by the time `startup_timeout` elapsed)
- `Invalid_input "initialize returned error: ..."` : the server reported an error (protocol version mismatch, for example)
- `Internal_error "transport closed"` : the child process exited during the handshake

`Mcp_server_failed` does not make `Runtime.create` return `Error` directly (except under fail-fast). Under `Log_and_continue`, the event fires first, and the runtime keeps running. The mapping from JSON-RPC error codes to `error_category` lives in `Mcp_errors.to_category`.

---

## Configuration Reference

`Mcp_types.server_config` fields:

```ocaml
type server_config = {
  name            : string;            (* Display name, also the base for server_id *)
  command         : string;            (* Executable path *)
  args            : string list;       (* Arguments *)
  env             : (string * string) list;  (* Additional environment variables *)
  cwd             : string option;     (* Child process working directory *)
  startup_timeout : float;             (* Initialize handshake timeout in seconds *)
}
```

| Field | Description | Typical values |
|------|------|--------|
| `name` | required. Duplicates get an automatic suffix | `"fs"`, `"git"`, `"github"` |
| `command` | required. Absolute path or `PATH`-resolvable executable name | `"npx"`, `"/usr/local/bin/mcp-server-fs"` |
| `args` | default `[]` | `[ "-y"; "@modelcontextprotocol/server-filesystem"; "/tmp" ]` |
| `env` | appended to the child process environment; missing keys are not overwritten | `[ ("GITHUB_TOKEN", "ghp_...") ]` |
| `cwd` | `None` means use the PAR process's cwd | `Some "/var/data"` |
| `startup_timeout` | seconds; handshake timeout returns an error | `5.0` to `30.0` |

### Naming rules

- `name = "fs"` produces `server_id = "fs"`
- A second `"fs"` automatically gets the suffix `"fs-1"`
- A third gets `"fs-2"`, and so on
- Comparison semantics are defined in `Mcp_types.server_id_compare` (lexicographic string order)

The full validation rules (length cap, allowed character set) live in `Mcp_naming.validate_server_name`; that module is also responsible for sanitizing server and tool names into the agent-visible tool name via `Mcp_naming.mangle_tool_name`.

### Environment variable isolation

The `env` field is **appended**, not replaced. The child process inherits the full environment of the PAR parent process, then layers the key/value pairs you provide on top. Safety recommendations:

- Pass secrets through files, not through `env` (the PAR bash tool sanitizes env, but MCP child processes have no such protection)
- Use `env` for debug flags only: `DEBUG=1`, `LOG_LEVEL=debug`, and similar non-sensitive values
- To clear a variable, write an empty string: `("FOO", "")`

---

## Type Reference

### capabilities

```ocaml
type capabilities = {
  tools     : bool;
  resources : bool;
  prompts   : bool;
  logging   : bool;
  sampling  : bool;
}
```

Declared by the server in the initialize response. PAR v0.3.1 reads it and stores it on the server state, queryable through `Mcp_client.capabilities`. PAR does not consume `logging` or `sampling`, but keeps them in the struct for protocol compatibility.

### Tools, resources, and prompts

```ocaml
type mcp_tool = {
  name         : string;
  description  : string option;  (* Human-readable description for the LLM *)
  title        : string option;
  input_schema : Yojson.Safe.t;  (* JSON Schema *)
}

type mcp_resource = {
  uri         : string;
  name        : string;
  description : string option;
  mime_type   : string option;
  title       : string option;
}

type mcp_prompt = {
  name        : string;
  description : string option;
  title       : string option;
  arguments   : mcp_prompt_arg list;  (* Argument metadata *)
}

type mcp_prompt_arg = {
  name        : string;
  description : string option;
  required    : bool;
}
```

### Other public types

```ocaml
type prefix_style =
  | Hierarchical
  | Flat
```

`prefix_style` is reserved for the v0.3.2+ tool naming convention. It is defined in v0.3.1 but no configuration knob is exposed yet. The actual mangling logic lives in `Mcp_naming.mangle_tool_name`.

```ocaml
type server_info = {
  name    : string;
  version : string;
}
```

The identifier the server reports in its initialize response. Available after a successful `Mcp_server.spawn` through the logs or through a custom RPC.

---

## Best Practices

### Choosing a startup policy

- **Production**: `Fail_fast`. If any server is unavailable, the runtime should not start successfully.
- **Development / local**: `Log_and_continue`, so an optional server (linter, formatter) can be missing without breaking the main flow.
- **CI**: `Log_and_continue`, so a missing MCP server does not turn the whole test suite red.

### Timeout settings

`startup_timeout` that is too short will misclassify slow-starting servers as failed; too long, and a broken server will block `Runtime.create`:

- Local `npx` startup: 10s is plenty
- Remote server pulling images: 30s
- Debug first-run (cold start plus dependency download): 60s

### Event monitoring

Wire `Mcp_server_failed` and `Mcp_tool_completed` into your monitoring system:

- A high rate of `Mcp_server_failed` means the config or the environment has a problem
- The `duration_ms` on `Mcp_tool_completed` feeds a P99 latency alert

### Do not pass secrets through env

MCP child processes do **not** go through PAR's `Bash_policy.sanitize_env`. The `env` field is a straight pass-through. If you need a token, write it to a file and let the MCP server read it itself, or pass it through an argument at startup.

---

## Current Limitations

v0.3.1 is the minimum viable MCP integration. The following capabilities are **not yet implemented**:

- sampling (server to LLM reverse call)
- roots / elicitation
- Multi-session concurrency (same `server_id` reuse, session pool)
- Streaming tool output

If any of those is a hard requirement, please file an issue with a scenario description.

---

## Security Audit Checklist

Before adding a new MCP server config, self-audit:

- [ ] `command` points at a trusted executable (avoid shell injection)
- [ ] `args` contains no sensitive information (it shows up in `ps` output)
- [ ] `env` does not carry secrets (write to a file or use a config center)
- [ ] `cwd` is an absolute path, to avoid ambiguity
- [ ] `startup_timeout` matches the server's real startup time
- [ ] The right `startup_policy` is chosen for the failure mode
- [ ] The event bus subscribes to `Mcp_server_failed` to detect anomalies
- [ ] `Mcp_tool_completed`'s `duration_ms` is wired into monitoring
- [ ] The child process exit code is audited through the return value of `Runtime.close`
- [ ] Any custom server implementation follows the MCP protocol (use the official SDK or test thoroughly)

## See also

- [`overview.md`](overview.md) : SDK architecture overview
- [`agent.md`](agent.md) : Agent definition, Runtime API, tool registration
- [`tools.md`](tools.md) : Built-in tools reference
- [`middleware.md`](middleware.md) : 7 built-in middlewares
- [MCP protocol specification](https://modelcontextprotocol.io) : server-side implementation reference
- [MCP server list](https://github.com/modelcontextprotocol/servers) : official and community server collection
