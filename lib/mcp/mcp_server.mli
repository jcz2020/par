(* lib/mcp/mcp_server.mli
   MCP server lifecycle + RPC dispatch. *)

(** A live, initialized MCP server connection. *)
type t

(** Server lifecycle status. *)
type status =
  | Starting
  | Ready of Mcp_types.capabilities
  | Failed of Types.error_category
  | Stopped

(** Spawn the child process, attach stdin/stdout to a transport,
    perform the initialize handshake. Returns once status is Ready
    or fails (per [startup_timeout]) with [Error category].

    Requires [process_mgr] (Eio.Stdenv.process_mgr env) and [clock]
    (Eio.Stdenv.clock env). [config] carries command, args, env, etc. *)
val spawn :
  sw:Eio.Switch.t ->
  ?process_mgr:_ Eio.Process.mgr ->
  ?net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  Mcp_types.server_config ->
  (t, Types.error_category) result

val id           : t -> Mcp_types.server_id
val name         : t -> string
val pid          : t -> int
val capabilities : t -> Mcp_types.capabilities
val status       : t -> status

(** Send a JSON-RPC request, await matching response.
    Generates a monotonic int id (per session), stores it in a pending
    table keyed by id, awaits the dispatch fiber to deliver the response. *)
val call_method :
  t -> method_:string -> params:Yojson.Safe.t ->
  (Yojson.Safe.t, Types.error_category) result

(** Send a JSON-RPC notification (no id, no response expected). *)
val notify :
  t -> method_:string -> params:Yojson.Safe.t ->
  (unit, Types.error_category) result

(** Send shutdown request, wait 2s for graceful exit, then SIGTERM (killpg),
    then wait 2s, then SIGKILL. Idempotent. *)
val stop : t -> (unit, Types.error_category) result
