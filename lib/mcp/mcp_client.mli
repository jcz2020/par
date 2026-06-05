(* lib/mcp/mcp_client.mli
   v0.3.1 W2 — High-level MCP client API. *)

(** A connected MCP client wrapping a live Mcp_server.t. *)
type t

(** Wrap an already-spawned server into a client. *)
val of_server : Mcp_server.t -> t

(** Underlying server handle. *)
val server : t -> Mcp_server.t

val id           : t -> Mcp_types.server_id
val name         : t -> string
val capabilities : t -> Mcp_types.capabilities
val status       : t -> Mcp_server.status

(** Spawn + handshake, returns a ready client.
    Equivalent to [Mcp_server.spawn] wrapped in a client handle. *)
val connect :
  sw:Eio.Switch.t ->
  process_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  Mcp_types.server_config ->
  (t, Types.error_category) result

(** Graceful shutdown. Delegates to [Mcp_server.stop]. *)
val disconnect : t -> (unit, Types.error_category) result

(** {2 Tools} *)

val list_tools : t -> (Mcp_types.mcp_tool list, Types.error_category) result

val call_tool :
  t -> name:string -> arguments:Yojson.Safe.t ->
  (Yojson.Safe.t, Types.error_category) result

(** {2 Resources} *)

val list_resources :
  t -> (Mcp_types.mcp_resource list, Types.error_category) result

val read_resource :
  t -> uri:string -> (Yojson.Safe.t, Types.error_category) result

(** {2 Prompts} *)

val list_prompts : t -> (Mcp_types.mcp_prompt list, Types.error_category) result

val get_prompt :
  t -> name:string -> ?arguments:(string * string) list -> unit ->
  (Yojson.Safe.t, Types.error_category) result

(** {2 Utility} *)

val ping : t -> (Yojson.Safe.t, Types.error_category) result
