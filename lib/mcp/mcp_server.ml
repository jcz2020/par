(* lib/mcp/mcp_server.ml
   v0.3.1 W2 — MCP server lifecycle + RPC dispatch (MCP-1).
   Spawns a child process, wires stdin/stdout to Mcp_transport_stdio,
   performs the JSON-RPC `initialize` handshake, and exposes
   request/notification APIs to the caller. *)

[@@@warning "-32-34-37-69"]

type status =
  | Starting
  | Ready of Mcp_types.capabilities
  | Failed of Types.error_category
  | Stopped

type t = {
  id           : Mcp_types.server_id;
  name         : string;
  pid          : int option;
  capabilities : Mcp_types.capabilities ref;
  mutable status : status;
  transport    : Mcp_transport.t;
  http_transport : Mcp_transport_http.t option;
  next_id      : int ref;
  mu           : Eio.Mutex.t;
  sleep        : float -> unit;
  sw           : Eio.Switch.t;
  stop_flag    : bool ref;
}

let id t = t.id
let name t = t.name
let pid t = Option.value t.pid ~default:0
let http_transport t = t.http_transport
let capabilities t = !(t.capabilities)
let status t = t.status

let lib_version = "0.3.0"

let build_initialize_params () : Yojson.Safe.t =
  `Assoc [
    "protocolVersion", `String Mcp_types.protocol_version;
    "capabilities", `Assoc [];
    "clientInfo", `Assoc [
      "name", `String "par";
      "version", `String lib_version;
    ];
  ]

let extract_capabilities (result_json : Yojson.Safe.t) : Mcp_types.capabilities =
  let caps_json =
    match result_json with
    | `Assoc fields ->
      (match List.assoc_opt "capabilities" fields with
       | Some j -> j
       | None -> `Assoc [])
    | _ -> `Assoc []
  in
  match Mcp_types.capabilities_of_yojson caps_json with
  | Ok caps -> caps
  | Error _ ->
    Mcp_types.capabilities_of_yojson (`Assoc []) |> Result.get_ok

let string_of_category (c : Types.error_category) : string = match c with
  | Types.Timeout -> "Timeout"
  | Types.Invalid_input s -> "Invalid_input(" ^ s ^ ")"
  | Types.External_failure s -> "External_failure(" ^ s ^ ")"
  | Types.Rate_limited -> "Rate_limited"
  | Types.Permission_denied s -> "Permission_denied(" ^ s ^ ")"
  | Types.Internal s -> "Internal(" ^ s ^ ")"

let call_method t ~method_ ~params :
  (Yojson.Safe.t, Types.error_category) result =
  let id =
    Eio.Mutex.use_rw t.mu ~protect:true (fun () ->
      let id = !(t.next_id) in
      t.next_id := id + 1;
      id)
  in
  let params_opt = match params with
    | `Null -> None
    | j -> Some j
  in
  let req : Mcp_types.jsonrpc_request = {
    id = Mcp_types.Int_id id;
    method_;
    params = params_opt;
  } in
  match t.transport.request_response req with
  | Error e -> Error e
  | Ok resp ->
    match resp.result with
    | Ok result -> Ok result
    | Error err ->
      let msg = Printf.sprintf "MCP server returned error %d: %s"
        err.code err.message in
      let category : Types.error_category =
        if err.code = -32601 then Types.Invalid_input msg
        else if err.code = -32602 then Types.Invalid_input msg
        else if err.code = -32600 then Types.Invalid_input msg
        else if err.code = -32700 then Types.Invalid_input msg
        else if err.code >= -32099 && err.code <= -32000 then
          Types.External_failure msg
        else if err.code = -32603 then Types.Internal msg
        else Types.Internal msg
      in
      Error category

let notify t ~method_ ~params :
  (unit, Types.error_category) result =
  let params_opt = match params with
    | `Null -> None
    | j -> Some j
  in
  let notif : Mcp_types.jsonrpc_notification = { method_; params = params_opt } in
  t.transport.notify notif

let kill_process pid =
  try Unix.kill (-pid) Sys.sigterm with _ -> ()
let force_kill_process pid =
  try Unix.kill (-pid) Sys.sigkill with _ -> ()

let process_alive pid =
  try
    let _ = Unix.kill (-pid) 0 in
    true
  with Unix.Unix_error (Unix.ESRCH, _, _) -> false

let wait_for_exit ~sleep pid ~timeout_s =
  let deadline_s = timeout_s in
  let rec loop elapsed =
    if elapsed >= deadline_s then false
    else
      if not (process_alive pid) then true
      else begin
        sleep 0.05;
        loop (elapsed +. 0.05)
      end
  in
  loop 0.0

let stop t : (unit, Types.error_category) result =
  match t.status with
  | Stopped -> Ok ()
  | _ ->
    t.transport.close ();
    (match t.pid with
     | None -> ()
     | Some pid ->
       let _ = wait_for_exit ~sleep:t.sleep pid ~timeout_s:2.0 in
       if process_alive pid then begin
         kill_process pid;
         let _ = wait_for_exit ~sleep:t.sleep pid ~timeout_s:2.0 in
         if process_alive pid then
           force_kill_process pid
       end);
    t.stop_flag := true;
    t.status <- Stopped;
    Ok ()

let next_instance_id = ref 0
let instance_mu = Eio.Mutex.create ()

let spawn ~sw ?process_mgr ?net ~clock (config : Mcp_types.server_config) :
  (t, Types.error_category) result =
  match Mcp_types.server_id_of_string (Mcp_types.server_name config) with
  | Error e -> Error e
  | Ok base_id ->
    let instance_num =
      Eio.Mutex.use_rw instance_mu ~protect:true (fun () ->
        incr next_instance_id;
        !next_instance_id)
    in
    let unique_id = Mcp_types.server_id_with_suffix base_id
        ("#" ^ string_of_int instance_num) in
    let transport_result =
      match config with
      | Mcp_types.Stdio_server cfg ->
        (match process_mgr with
         | None ->
           Error (Types.Invalid_input "Mcp_server.spawn: Stdio_server requires ~process_mgr")
         | Some mgr ->
           (match Mcp_transport_stdio.spawn_with ~sw ~process_mgr:mgr
              ~command:cfg.command ~args:cfg.args
              ~env:cfg.env ?cwd:cfg.cwd config with
            | Error e -> Error e
            | Ok (transport, pid) -> Ok (Mcp_transport_stdio.to_transport transport, Some pid, None)))
      | Mcp_types.Http_server cfg ->
        (match net with
         | None ->
           Error (Types.Invalid_input "Mcp_server.spawn: Http_server requires ~net")
         | Some net ->
           let http = Mcp_transport_http.create ~url:cfg.url ~net ~sw in
           Ok (Mcp_transport_http.to_transport http, None, Some http))
    in
     (match transport_result with
      | Error e -> Error e
      | Ok (transport, pid, http_t) ->
       let next_id = ref 0 in
       let mu = Eio.Mutex.create () in
       let capabilities = ref
         { Mcp_types.tools = false; resources = false; prompts = false;
           logging = false; sampling = false } in
       let stop_flag = ref false in
       let sleep_fn = (fun s -> Eio.Time.sleep clock s) in
       let rec_t : t = {
         id = unique_id;
         name = Mcp_types.server_name config;
         pid;
         capabilities;
         status = Starting;
         transport;
         http_transport = http_t;
         next_id;
         mu;
         sleep = sleep_fn;
         sw;
         stop_flag;
       } in
       let init_params = build_initialize_params () in
       let timeout_s = Mcp_types.server_startup_timeout config in
       let init_result =
         Eio.Fiber.first
           (fun () ->
             call_method rec_t ~method_:Mcp_types.method_initialize
               ~params:init_params)
           (fun () ->
             Eio.Time.sleep clock timeout_s;
             Error (Timeout : Types.error_category))
       in
       (match init_result with
        | Error e ->
          let pid_str =
            match rec_t.pid with
            | Some p -> Printf.sprintf "pid %d" p
            | None -> "http"
          in
          Logs.warn (fun m ->
            m "MCP server %s (%s) handshake failed: %s"
              rec_t.name pid_str (string_of_category e));
          let _ = stop rec_t in
          rec_t.status <- Failed e;
          Error e
        | Ok result ->
          let caps = extract_capabilities result in
          rec_t.capabilities := caps;
          rec_t.status <- Ready caps;
          let pid_str =
            match rec_t.pid with
            | Some p -> Printf.sprintf "pid %d" p
            | None -> "http"
          in
          Logs.info (fun m ->
            m "MCP server %s (%s) ready: tools=%b resources=%b prompts=%b"
              rec_t.name pid_str caps.Mcp_types.tools caps.Mcp_types.resources
              caps.Mcp_types.prompts);
          let _ =
            notify rec_t ~method_:Mcp_types.method_initialized
              ~params:(`Assoc [])
          in
          Ok rec_t))
