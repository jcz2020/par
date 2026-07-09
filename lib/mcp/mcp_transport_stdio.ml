(* lib/mcp/mcp_transport_stdio.ml
   v0.3.1 W2 — JSON-RPC 2.0 over stdio transport (MCP spec §3.1).

   Line-delimited JSON framing on a [Eio.Flow.sink] / [Eio.Flow.source] pair.
   1 MB max message size, mutex on writes for concurrent sends, and a
   [Test.pair] in-memory duplex for hermetic unit tests. *)

[@@@warning "-32-34-37"]

let max_message_size = 1_048_576

type t = {
  write_fn  : Cstruct.t -> unit;
  close_fn  : unit -> unit;
  read      : Eio.Buf_read.t;
  mu        : Eio.Mutex.t;
  closed    : bool ref;
  read_done : bool ref;
}

let strip_cr s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s

let is_comment_line s = String.length s > 0 && s.[0] = '#'

let is_request_to_server (j : Yojson.Safe.t) : bool =
  match j with
  | `Assoc fields ->
    List.mem_assoc "id" fields
    && not (List.mem_assoc "result" fields)
    && not (List.mem_assoc "error" fields)
  | _ -> false

let has_method_ (j : Yojson.Safe.t) : bool =
  match j with
  | `Assoc fields -> List.mem_assoc "method" fields
  | _ -> false

let is_response_shape (j : Yojson.Safe.t) : bool =
  match j with
  | `Assoc fields ->
    List.mem_assoc "id" fields
    && (List.mem_assoc "result" fields || List.mem_assoc "error" fields)
  | _ -> false

let classify json :
    ([> `Response of Mcp_types.jsonrpc_response
     | `Notification of Mcp_types.jsonrpc_notification ], string) result =
  if is_response_shape json then begin
    match Mcp_types.response_of_yojson json with
    | Ok v -> Ok (`Response v)
    | Error e -> Error e
  end else if has_method_ json then begin
    if is_request_to_server json then
      Error "MCP server-to-client requests not supported in v0.3.1"
    else
      match Mcp_types.notification_of_yojson json with
      | Ok v -> Ok (`Notification v)
      | Error e -> Error e
  end else
    Error "MCP message missing required fields"

let create_internal ~sink:(sink : [> Eio.Flow.sink_ty] Eio.Resource.t)
    ~source:(source : [> Eio.Flow.source_ty] Eio.Resource.t) ~close_fn =
  let read =
    Eio.Buf_read.of_flow ~initial_size:4096 ~max_size:max_message_size source
  in
  let write_fn cs = Eio.Flow.write sink [cs] in
  {
    write_fn;
    close_fn;
    read;
    mu = Eio.Mutex.create ();
    closed = ref false;
    read_done = ref false;
  }

let create ~sink ~source =
  create_internal ~sink ~source ~close_fn:(fun () -> ())

let write_with_lock t (s : string) :
    (unit, Types.error_category) result =
  if !(t.closed) then
    Error (Types.External_failure "transport closed")
  else
    Eio.Mutex.use_rw t.mu ~protect:true (fun () ->
      let result : (unit, Types.error_category) result =
        try
          t.write_fn (Cstruct.of_string s);
          Ok ()
        with
        | Eio.Io _ as ex ->
          let msg = Printf.sprintf "transport write failed: %s"
            (Printexc.to_string ex) in
          Error (Types.External_failure msg)
      in
      result)

let send_request t req =
  let json = Mcp_types.request_to_yojson req in
  let s = Printf.sprintf "%s\n" (Yojson.Safe.to_string json) in
  write_with_lock t s

let send_notification t notif =
  let json = Mcp_types.notification_to_yojson notif in
  let s = Printf.sprintf "%s\n" (Yojson.Safe.to_string json) in
  write_with_lock t s

let read_one_line t : (string, Types.error_category) result =
  if !(t.read_done) then
    Error (Types.External_failure "MCP server closed connection")
  else begin
    try
      let line = Eio.Buf_read.line t.read in
      Ok (strip_cr line)
    with
    | Eio.Buf_read.Buffer_limit_exceeded ->
      t.read_done := true;
      Error
        (Types.Invalid_input
           (Printf.sprintf "MCP message exceeds %d-byte limit"
              max_message_size))
    | End_of_file ->
      t.read_done := true;
      Error (Types.External_failure "MCP server closed connection")
    | Eio.Io _ as ex ->
      t.read_done := true;
      let msg = Printf.sprintf "transport read failed: %s"
        (Printexc.to_string ex) in
      Error (Types.External_failure msg)
  end

let parse_one (line : string) :
    (([> `Response of Mcp_types.jsonrpc_response
      | `Notification of Mcp_types.jsonrpc_notification ] as 'a),
     Types.error_category) result =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error msg ->
    Logs.debug (fun m ->
      m "transport_stdio: skipping non-JSON line: %s" msg);
    Error (Types.Invalid_input ("not JSON: " ^ msg))
  | json ->
    match classify json with
    | Ok v -> Ok v
    | Error e ->
      Logs.debug (fun m ->
        m "transport_stdio: classification failed: %s" e);
      Error (Types.Invalid_input e)

let rec recv_message t :
    ([ `Response of Mcp_types.jsonrpc_response
     | `Notification of Mcp_types.jsonrpc_notification ],
     Types.error_category) result =
  match read_one_line t with
  | Error _ as e -> e
  | Ok line ->
    if is_comment_line line then recv_message t
    else
      match parse_one line with
      | Ok v -> Ok v
      | Error (Types.Invalid_input _) ->
        (* Frame skip per TS-SDK mode: advance to next line. *)
        recv_message t
      | Error _ as e -> e

let close t =
  if !(t.closed) then ()
  else begin
    t.closed := true;
    t.close_fn ()
  end

let default_child_env () =
  let whitelist = ["HOME"; "LOGNAME"; "PATH"; "SHELL"; "TERM"; "USER"] in
  List.filter_map
    (fun name ->
      try Some (name, Unix.getenv name)
      with Not_found -> None)
    whitelist

let env_to_array env =
  Array.of_list
    (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) env)

let spawn_with ~sw ~process_mgr ~command ~args ?env ?cwd ?stdin_timeout
    (_config : Mcp_types.server_config) :
    (t * int, Types.error_category) result =
  let _ = (cwd, stdin_timeout) in
  (match Capability.detect () `Process_spawning with
   | `Unavailable reason ->
     Error (Types.Internal
       (Printf.sprintf "MCP stdio transport unavailable: %s" reason))
   | `Available ->
  let base_env = default_child_env () in
  let user_env = Option.value ~default:[] env in
  (* User env takes precedence on duplicate keys. *)
  let env_pairs =
    let acc = Hashtbl.create 16 in
    List.iter (fun (k, v) -> Hashtbl.replace acc k v) base_env;
    List.iter (fun (k, v) -> Hashtbl.replace acc k v) user_env;
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) acc []
  in
  let env_array = env_to_array env_pairs in
  let stdin_src, stdin_sink = Eio.Process.pipe ~sw process_mgr in
  let stdout_src, stdout_sink = Eio.Process.pipe ~sw process_mgr in
  try
    let proc =
      Eio.Process.spawn ~sw process_mgr
        ~stdin:stdin_src
        ~stdout:stdout_sink
        ~env:env_array
        (command :: args)
    in
    let pid = Eio.Process.pid proc in
    let transport = create_internal ~sink:stdin_sink ~source:stdout_src
        ~close_fn:(fun () -> Eio.Flow.close stdin_sink) in
    Ok (transport, pid)
  with
  | ex ->
    let msg = Printf.sprintf "spawn %s failed: %s"
      command (Printexc.to_string ex) in
    Error (Types.External_failure msg)
  )

let to_transport (t : t) : Mcp_transport.t = {
  request_response = (fun req ->
    match send_request t req with
    | Error _ as e -> e
    | Ok () ->
      let rec loop () =
        match recv_message t with
        | Ok (`Response r) when Mcp_types.request_id_matches r.Mcp_types.id req.Mcp_types.id ->
          Ok r
        | Ok _ -> loop ()
        | Error _ as e -> e
      in
      loop ());
  notify = (fun notif -> send_notification t notif);
  close = (fun () -> close t);
}

module Test = struct
  let pair ~sw ~mgr () =
    let p1_src, p1_sink = Eio.Process.pipe ~sw mgr in
    let p2_src, p2_sink = Eio.Process.pipe ~sw mgr in
    let client = create_internal ~sink:p1_sink ~source:p2_src
        ~close_fn:(fun () -> Eio.Flow.close p1_sink) in
    let server = create_internal ~sink:p2_sink ~source:p1_src
        ~close_fn:(fun () -> Eio.Flow.close p2_sink) in
    (client, server)

  let write_raw t s = t.write_fn (Cstruct.of_string s)
end
