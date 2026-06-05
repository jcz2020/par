(* lib/mcp/mcp_transport_stdio.mli
   v0.3.1 W2 design — JSON-RPC 2.0 over stdio (MCP spec §3.1).
   See docs/v0.3.1-ROADMAP.md §MCP-1.

   Implements line-delimited JSON framing (LF separator, optional CR stripping),
   1 MB max message size, mutex on writes for concurrent sends, and a [Test.pair]
   in-memory duplex for hermetic unit tests.

   Public type abbreviations intentionally not exposed: callers see [t] and the
   [Test] submodule only.  Internal representation may change without notice. *)

(** A duplex transport over a child process's stdin/stdout.
    Internally: an [Eio.Buf_write.t] (to server) + [Eio.Buf_read.t] (from server). *)
type t

(** Construct a transport from raw Eio flows. Caller owns the underlying process.

    @param sink  Eio flow that the transport writes to (the child's stdin view).
    @param source Eio flow that the transport reads from (the child's stdout view).
    @return A transport with a live flush fiber attached to an internal switch. *)
val create :
  sink:[> Eio.Flow.sink_ty ] Eio.Resource.t ->
  source:[> Eio.Flow.source_ty ] Eio.Resource.t ->
  t

(** Send a JSON-RPC request. Serializes to one line plus a trailing '\n'.
    Mutex-protected: safe to call from multiple fibers concurrently.

    @return [Ok ()] on success, or [Error category] on I/O failure. *)
val send_request : t -> Mcp_types.jsonrpc_request -> (unit, Types.error_category) result

(** Send a JSON-RPC notification (no id). Mutex-protected.

    @return [Ok ()] on success, or [Error category] on I/O failure. *)
val send_notification :
  t -> Mcp_types.jsonrpc_notification -> (unit, Types.error_category) result

(** Receive one message. Skips lines that start with '#' (LSP-style comments)
    and lines that fail to parse as JSON (TS-SDK "frame skip" mode).
    Strips a single trailing '\r' from each line before parsing.

    @return [`Response _] for a JSON-RPC response,
            [`Notification _] for a JSON-RPC notification,
            or [Error (Invalid_input "...")] for a malformed / hybrid message,
            or [Error (External_failure "MCP server closed connection")] on EOF. *)
val recv_message :
  t ->
  ([ `Response of Mcp_types.jsonrpc_response
   | `Notification of Mcp_types.jsonrpc_notification ],
   Types.error_category) result

(** Idempotent. Subsequent calls return [Ok ()]. Closes the write half,
    which signals EOF to the server and triggers its shutdown cascade. *)
val close : t -> unit

(** Default environment for spawned MCP servers — POSIX whitelist.
    Hardcoded in v0.3.1: [HOME, LOGNAME, PATH, SHELL, TERM, USER].
    Prevents secret leak (e.g. [AWS_SECRET_KEY], [GITHUB_TOKEN]) to npm packages.
    v0.4 evaluates [?mcp_default_env : [`Strict | `Inherit_all]]. *)
val default_child_env : unit -> (string * string) list

(** Convenience: spawn a process and wire it to a [t].
    Returns the transport + child PID for lifecycle management.
    Applies [default_child_env] first, then user-supplied [env] (user takes precedence).

    @param sw  Switch controlling the child + the transport's flush fiber.
    @param process_mgr  Eio process manager from the runtime.
    @param command  Executable to run.
    @param args  Arguments to pass.
    @param env  Additional environment variables (merged on top of the POSIX whitelist).
    @param cwd  Optional working directory.
    @param stdin_timeout  Optional timeout (seconds) for writes to the child's stdin.
    @param config  Server config (currently unused beyond lifecycle; reserved for v0.3.2 hooks). *)
val spawn_with :
  sw:Eio.Switch.t ->
  process_mgr:_ Eio.Process.mgr ->
  command:string -> args:string list ->
  ?env:(string * string) list -> ?cwd:string -> ?stdin_timeout:float ->
  Mcp_types.server_config ->
  (t * int, Types.error_category) result

module Test : sig
  (** Pair of in-memory transports for hermetic unit tests.
      [pair ~sw ~mgr ()] returns [(client_t, server_t)] such that:
      - bytes the client writes to [client_t] are readable from [server_t]
      - bytes the server writes to [server_t] are readable from [client_t]
      The two pipes are backed by OS pipes (POSIX); no real child process is spawned.
      The pipes are attached to [sw], so the caller controls when they are torn down.
      [mgr] must come from the active Eio env (e.g. [Eio.Stdenv.process_mgr env]). *)
  val pair : sw:Eio.Switch.t -> mgr:_ Eio.Process.mgr -> unit -> t * t

  (** Write raw bytes (e.g. a pre-built JSON response) to the transport's sink.
      Used by tests to inject server-side responses / arbitrary framed lines.
      NOT part of the public JSON-RPC API. *)
  val write_raw : t -> string -> unit
end
