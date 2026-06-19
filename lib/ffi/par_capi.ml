(* par_capi.ml — OCaml side of the C FFI bridge.
    Registers OCaml functions via Callback.register so C code can call them.
    Uses an Eio event loop thread to serialize all Runtime operations. *)

open Par
let () = ()
(* Force module load order: Health, Metrics, Runtime, Hook are referenced. *)

let json_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c -> match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c < 32 ->
      Printf.bprintf buf "\\u%04x" (Char.code c)
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let error_json msg =
  Printf.sprintf "{\"error\": \"%s\"}" (json_escape msg)

type ffi_handle = {
  rt : Par.Runtime.runtime;
}

let handles : (int, ffi_handle) Hashtbl.t = Hashtbl.create 8
let handle_counter = ref 0

let alloc_handle h =
  incr handle_counter;
  let id = !handle_counter in
  Hashtbl.add handles id h;
  id

let get_handle id =
  try Some (Hashtbl.find handles id)
  with Not_found -> None

let free_handle id =
  Hashtbl.remove handles id

let unwrap : string option -> Obj.t = function
  | Some v -> Obj.repr v
  | None -> Obj.repr "{\"error\": \"internal: no response from worker\"}"

let shutdown_flag = ref false

let do_init (config_json : string) =
  let json = Yojson.Safe.from_string config_json in
  let config = match Par.Types.runtime_config_of_yojson json with
    | Ok c -> c
    | Error s -> failwith (Printf.sprintf "Invalid config JSON: %s" s)
  in
  (* Run Eio_main.run in a fresh domain. This is required because
     Eio_main.run must be the entry point of an application — calling
     it from a C callback (which is what we are, via par_init) hangs
     because the event loop never gets to start.
     See [par_ffi.c] for the C-side mirror of this design. *)
  let result_dom = Domain.spawn (fun () ->
    Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
        match Par.Runtime.create ~config sw with
        | Ok r -> r
        | Error _ -> failwith "Runtime.create failed"
      )
    )
  ) in
  let rt = Domain.join result_dom in
  let handle = { rt } in
  let id = alloc_handle handle in
  Obj.repr id

let do_shutdown (id : int) =
  match get_handle id with
  | None -> error_json "Invalid runtime handle"
  | Some handle ->
    shutdown_flag := true;
    (try let _ = Par.Runtime.close handle.rt in ()
     with ex -> Logs.err (fun m -> m "par_capi: Runtime.close failed: %s" (Printexc.to_string ex)));
    free_handle id;
    "{\"status\": \"ok\"}"

(* Return codes for par_register_tool:
   0  = success
   -1 = general error (e.g. invalid handle, internal failure)
   -2 = invalid JSON schema (malformed JSON or not an object)
   -3 = empty tool name
   -4 = duplicate tool name *)

let do_register_tool (id : int) (name : string) (desc : string) (schema : string) =
  match get_handle id with
  | None -> Obj.repr (-1)
  | Some handle ->
    if String.length name = 0 then Obj.repr (-3)
    else
      (try
         let json_schema = Yojson.Safe.from_string schema in
         (match json_schema with
          | `Assoc _ ->
             if Par.Tool_registry.resolve (Par.Runtime.tool_registry handle.rt) name <> None
             then Obj.repr (-4)
             else
               (match Par.Runtime.register_tool handle.rt
                  ~name ~description:desc
                  ~input_schema:json_schema
                  ~handler:(fun input _token ->
                    Logs.warn (fun m ->
                      m "FFI tool '%s': no-op handler invoked \
                         (Python callback not yet supported)" name);
                    Par.Types.Success input)
                  () with
                | Ok _ -> Obj.repr 0
                | Error _ -> Obj.repr (-4))
          | _ -> Obj.repr (-2))
       with
        | Yojson.Json_error _ -> Obj.repr (-2)
        | _ -> Obj.repr (-1))

external c_invoke_python_handler : int -> string -> string = "caml_invoke_python_handler"

let do_register_tool_with_handler (id : int) (name : string) (desc : string)
    (schema : string) (handler_id : int) =
  match get_handle id with
  | None -> Obj.repr (-1)
  | Some handle ->
    if String.length name = 0 then Obj.repr (-3)
    else
      (try
         let json_schema = Yojson.Safe.from_string schema in
         (match json_schema with
          | `Assoc _ ->
             if Par.Tool_registry.resolve (Par.Runtime.tool_registry handle.rt) name <> None
             then Obj.repr (-4)
             else
                let handler_fn input _token =
                  let input_str = Yojson.Safe.to_string input in
                  let result_str = c_invoke_python_handler handler_id input_str in
                  let open Par.Types in
                  if String.length result_str = 0 then
                    Error {
                      category = Internal "python handler returned empty";
                      message = Printf.sprintf "Python handler %d returned empty" handler_id;
                      retryable = false;
                      metadata = [];
                    }
                  else
                    (try Success (Yojson.Safe.from_string result_str)
                     with _ ->
                       Error {
                         category = Internal "invalid JSON from Python handler";
                         message = "Python handler returned invalid JSON";
                         retryable = false;
                         metadata = [];
                       })
               in
               (match Par.Runtime.register_tool handle.rt
                  ~name ~description:desc
                  ~input_schema:json_schema
                  ~handler:handler_fn
                  () with
                | Ok _ -> Obj.repr 0
                | Error _ -> Obj.repr (-4))
          | _ -> Obj.repr (-2))
       with
       | Yojson.Json_error _ -> Obj.repr (-2)
       | _ -> Obj.repr (-1))

let parse_provider (s : string) : [> `Openai | `Anthropic | `Ollama | `Custom of string ] =
  match String.lowercase_ascii s with
  | "openai" -> `Openai
  | "anthropic" -> `Anthropic
  | "ollama" -> `Ollama
  | s -> `Custom s

let parse_model_config (json : Yojson.Safe.t) : Par.Types.model_config =
  let open Yojson.Safe.Util in
  let provider_str = json |> member "provider" |> to_string_option |> Option.value ~default:"openai" in
  let provider = parse_provider provider_str in
  let model_name = json |> member "model_name" |> to_string in
  let api_base = json |> member "api_base" |> to_string_option in
  let temperature = json |> member "temperature" |> to_float_option |> Option.value ~default:0.7 in
  let max_tokens = json |> member "max_tokens" |> to_int_option in
  let top_p = json |> member "top_p" |> to_float_option in
  let stop_sequences = json |> member "stop_sequences" |> to_list |> List.filter_map to_string_option |> Option.some in
  { provider; model_name; api_base; temperature; max_tokens; top_p; stop_sequences }

let parse_system_prompt_template (json : Yojson.Safe.t) : Par.Types.system_prompt_template =
  let open Yojson.Safe.Util in
  let template = json |> member "template" |> to_string in
  let variables = json |> member "variables" |> to_list |> List.filter_map to_string_option in
  let required = json |> member "required" |> to_list |> List.filter_map to_string_option in
  { template; variables; required }

let parse_tool_descriptor (json : Yojson.Safe.t) : Par.Types.tool_descriptor =
  let open Yojson.Safe.Util in
  let name = json |> member "name" |> to_string in
  let description = json |> member "description" |> to_string in
  let input_schema = json |> member "input_schema" in
  let permission = Par.Types.Allow in
  let timeout = json |> member "timeout" |> to_float_option in
  let concurrency_limit = json |> member "concurrency_limit" |> to_int_option in
  { name; description; input_schema; output_schema = None; permission; timeout; concurrency_limit; on_update = None }

let parse_resource_quota (json : Yojson.Safe.t) : Par.Types.resource_quota =
  let open Yojson.Safe.Util in
  let max_concurrent_tasks = json |> member "max_concurrent_tasks" |> to_int_option |> Option.value ~default:max_int in
  let max_concurrent_tools_per_agent = json |> member "max_concurrent_tools_per_agent" |> to_int_option |> Option.value ~default:max_int in
  let max_tokens_per_turn = json |> member "max_tokens_per_turn" |> to_int_option in
  let max_total_tokens = json |> member "max_total_tokens" |> to_int_option in
  { max_concurrent_tasks; max_concurrent_tools_per_agent; max_tokens_per_turn; max_total_tokens }

let parse_agent_config (json : Yojson.Safe.t) : Par.Types.agent_config =
  let open Yojson.Safe.Util in
  let id = json |> member "id" |> to_string in
  let system_prompt = json |> member "system_prompt" |> to_string in
  let system_prompt_template = match json |> member "system_prompt_template" with
    | `Assoc _ as v -> Some (parse_system_prompt_template v)
    | _ -> None
  in
  let model = json |> member "model" |> parse_model_config in
  let tools = json |> member "tools" |> to_list |> List.map parse_tool_descriptor in
  let max_iterations = json |> member "max_iterations" |> to_int_option |> Option.value ~default:10 in
  let middleware = [] in
  let retry_policy = None in
  let context_strategy = None in
  let resource_quota = match json |> member "resource_quota" with
    | `Assoc _ as v -> Some (parse_resource_quota v)
    | _ -> None
  in
  { id; system_prompt; system_prompt_template; model; tools; max_iterations;
    middleware; retry_policy; context_strategy; resource_quota }

let do_register_agent (id : int) (config_json : string) =
  match get_handle id with
  | None -> Obj.repr (-1)
  | Some handle ->
    (try
       let json = Yojson.Safe.from_string config_json in
       let config = parse_agent_config json in
       match Par.Runtime.register_agent handle.rt config with
       | Ok () -> Obj.repr 0
       | Error _ -> Obj.repr (-1)
     with
     | _ -> Obj.repr (-1))

let do_invoke (id : int) (agent_id : string) (message : string) =
  match get_handle id with
  | None -> None
  | Some handle ->
    (try
        let result = Par.Runtime.invoke handle.rt
          ~agent_id ~message () in
        let json = match result with
          | Ok { Par.Types.response = resp; conversation = _ } ->
            Printf.sprintf "{\"status\": \"ok\", \"content\": %s}"
              (Yojson.Safe.to_string (Par.Types.llm_response_to_yojson resp))
          | Error (err, _) ->
            error_json (Printf.sprintf "Invoke failed: %s"
              (Yojson.Safe.to_string (Par.Types.error_category_to_yojson err)))
       in
       Some json
     with e -> Some (error_json (Printexc.to_string e)))

let do_invoke_structured (id : int) (agent_id : string) (message : string) (schema_json : string) =
  match get_handle id with
  | None -> None
  | Some handle ->
    (try
       let response_schema = Yojson.Safe.from_string schema_json in
       let result = Par.Runtime.invoke_structured handle.rt
         ~agent_id ~message ~response_schema () in
       let json = match result with
         | Ok { Par.Types.value; raw_response; conversation = _; attempts } ->
           Printf.sprintf
             "{\"status\": \"ok\", \"value\": %s, \"raw\": %s, \"attempts\": %d}"
             (Yojson.Safe.to_string value)
             (Yojson.Safe.to_string (Par.Types.llm_response_to_yojson raw_response))
             attempts
         | Error (err, _) ->
           error_json (Printf.sprintf "Invoke_structured failed: %s"
             (Yojson.Safe.to_string (Par.Types.error_category_to_yojson err)))
       in
       Some json
     with e -> Some (error_json (Printexc.to_string e)))

let parse_workflow (json : Yojson.Safe.t) : Par.Types.workflow =
  let open Yojson.Safe.Util in
  let id = json |> member "id" |> to_string in
  let name = json |> member "name" |> to_string in
  let version = json |> member "version" |> to_int_option |> Option.value ~default:1 in
  let steps_json = json |> member "steps" in
  let steps = match Par.Types.workflow_step_of_yojson steps_json with
    | Ok s -> s
    | Error _ -> Par.Types.Sequential []
  in
  let variables_json = json |> member "variables" |> to_assoc |> List.map (fun (k, v) -> (k, v)) in
  let failure_policy = Par.Types.Fail_fast in
  let parallel_limit = json |> member "parallel_limit" |> to_int_option |> Option.value ~default:4 in
  let timeout = json |> member "timeout" |> to_float_option |> Option.value ~default:3600.0 in
  let on_complete = None in
  { id; name; version; steps; variables = variables_json;
    failure_policy; parallel_limit; timeout; on_complete }

let do_submit_workflow (id : int) (workflow_json : string) =
  match get_handle id with
  | None -> None
  | Some handle ->
    (try
       let json = Yojson.Safe.from_string workflow_json in
       let wf = parse_workflow json in
       match Par.Runtime.submit_workflow handle.rt wf with
       | Ok run_id ->
         let json_response = Printf.sprintf "{\"status\": \"ok\", \"workflow_run_id\": \"%s\"}"
           (Par.Types.Workflow_run_id.to_string run_id)
         in
         Some json_response
       | Error err ->
         Some (error_json (Printf.sprintf "submit_workflow failed: %s"
           (Yojson.Safe.to_string (Par.Types.error_category_to_yojson err))))
     with e -> Some (error_json (Printexc.to_string e)))

let do_approve_workflow (id : int) (run_id : string) (approver : string) =
  match get_handle id with
  | None -> -1
  | Some handle ->
    (try
       let wf_id = Par.Types.Workflow_run_id.of_string run_id in
       let result = Par.Runtime.approve_workflow handle.rt wf_id ~approver in
       (match result with
        | Ok () -> 0
        | Error _ -> -1)
     with _ -> -1)

let do_resume_workflow (id : int) (run_id : string) =
  match get_handle id with
  | None -> None
  | Some handle ->
    (try
       let wf_id = Par.Types.Workflow_run_id.of_string run_id in
       let result = Par.Runtime.resume_workflow handle.rt wf_id in
       let json = match result with
         | Ok (Some wf_result) ->
           Printf.sprintf "{\"status\": \"ok\", \"result\": %s}"
             (Yojson.Safe.to_string (Par.Types.workflow_result_to_yojson wf_result))
         | Ok None -> "{\"status\": \"ok\", \"result\": null}"
         | Error err ->
           error_json (Printf.sprintf "resume_workflow failed: %s"
             (Yojson.Safe.to_string (Par.Types.error_category_to_yojson err)))
       in
       Some json
      with e -> Some (error_json (Printexc.to_string e)))

let do_mcp_server (id : int) (sid : string) : string option =
  match get_handle id with
  | None -> Some (error_json "Invalid runtime handle")
  | Some handle ->
    (try
      match Par.Mcp_types.server_id_of_string sid with
      | Error e -> Some (error_json (Yojson.Safe.to_string (Par.Types.error_category_to_yojson e)))
      | Ok server_id ->
        (match Par.Runtime.mcp_server handle.rt server_id with
         | Error e -> Some (error_json (Yojson.Safe.to_string (Par.Types.error_category_to_yojson e)))
         | Ok _server ->
           Some "{\"status\": \"ok\", \"note\": \"mcp_server connected\"}")
     with e ->
       Some (error_json (Printexc.to_string e)))

let do_mcp_list_tools (id : int) (sid : string) : string option =
  match get_handle id with
  | None -> Some (error_json "Invalid runtime handle")
  | Some handle ->
    (try
      match Par.Mcp_types.server_id_of_string sid with
      | Error e -> Some (error_json (Yojson.Safe.to_string (Par.Types.error_category_to_yojson e)))
      | Ok server_id ->
        (match Par.Runtime.mcp_server handle.rt server_id with
         | Error e -> Some (error_json (Yojson.Safe.to_string (Par.Types.error_category_to_yojson e)))
         | Ok server ->
           let tools = Par.Mcp_client.list_tools (Par.Mcp_client.of_server server) in
           (match tools with
            | Error e -> Some (error_json (Yojson.Safe.to_string (Par.Types.error_category_to_yojson e)))
            | Ok tl ->
              let arr = List.map (fun (t : Par.Mcp_types.mcp_tool) ->
                Printf.sprintf "{\"name\":\"%s\"}" (json_escape t.Par.Mcp_types.name)
              ) tl in
              Some (Printf.sprintf "{\"tools\":[%s]}" (String.concat "," arr))))
     with e ->
       Some (error_json (Printexc.to_string e)))

let do_workflow_status (id : int) (run_id : string) : string option =
  match get_handle id with
  | None -> Some (error_json "Invalid runtime handle")
  | Some _handle ->
    (try
      Some (Printf.sprintf "{\"run_id\":\"%s\",\"status\":\"unknown\"}" (json_escape run_id))
     with e ->
       Some (error_json (Printexc.to_string e)))

let do_workflow_cancel (id : int) (_run_id : string) : int =
  match get_handle id with
  | None -> -1
  | Some _handle -> -1

let do_event_subscribe (_id : int) (_cb : int) : int = -1

 let do_version () : string = Par.Version.version

let () =
  Callback.register "par_init" (fun (config_json : string) ->
    do_init config_json)

let () =
  Callback.register "par_shutdown" (fun (_rt_val : Obj.t) ->
    let id = Obj.magic _rt_val in
    do_shutdown id)

let () =
  Callback.register "par_register_tool"
    (fun (rt_val : Obj.t) (name : string) (desc : string) (schema : string) ->
      let id = Obj.magic rt_val in
      do_register_tool id name desc schema)

let () =
  Callback.register "par_register_tool_with_handler"
    (fun (rt_val : Obj.t) (name : string) (desc : string) (schema : string) (handler_id : int) ->
      let id = Obj.magic rt_val in
      do_register_tool_with_handler id name desc schema handler_id)

let () =
  Callback.register "par_register_agent"
    (fun (rt_val : Obj.t) (config_json : string) ->
      let id = Obj.magic rt_val in
      do_register_agent id config_json)

let () =
  Callback.register "par_invoke"
    (fun (rt_val : Obj.t) (agent_id : string) (message : string) ->
      let id = Obj.magic rt_val in
      unwrap (do_invoke id agent_id message))

let () =
  Callback.register "par_invoke_structured"
    (fun (rt_val : Obj.t) (agent_id : string) (message : string) (schema_json : string) ->
      let id = Obj.magic rt_val in
      unwrap (do_invoke_structured id agent_id message schema_json))

let () =
  Callback.register "par_submit_workflow"
    (fun (rt_val : Obj.t) (workflow_json : string) ->
      let id = Obj.magic rt_val in
      unwrap (do_submit_workflow id workflow_json))

let () =
  Callback.register "par_approve_workflow"
    (fun (rt_val : Obj.t) (run_id : string) (approver : string) ->
      let id = Obj.magic rt_val in
      do_approve_workflow id run_id approver)

let () =
  Callback.register "par_resume_workflow"
    (fun (rt_val : Obj.t) (run_id : string) ->
      let id = Obj.magic rt_val in
      unwrap (do_resume_workflow id run_id))

let do_health (id : int) : string =
  match get_handle id with
  | None -> error_json "Invalid runtime handle"
  | Some handle ->
    let h = Par.Runtime.health handle.rt in
    let json = Printf.sprintf
      "{\"status\": \"ok\", \"runtime_alive\": %s, \"persistence_ok\": %s, \
       \"last_llm_call_at\": %s, \"last_llm_call_status\": \"%s\"}"
      (if h.runtime_alive then "true" else "false")
      (if h.persistence_ok then "true" else "false")
      (match h.last_llm_call_at with Some f -> Printf.sprintf "%f" f | None -> "null")
      (match h.last_llm_call_status with
       | `Success -> "Success" | `Never_called -> "Never_called"
       | `Error (Types.Internal _) -> "Error.Internal"
       | `Error (Types.Timeout) -> "Error.Timeout"
       | `Error (Types.Invalid_input _) -> "Error.Invalid_input"
       | `Error (Types.External_failure _) -> "Error.External_failure"
       | `Error (Types.Rate_limited) -> "Error.Rate_limited"
       | `Error (Types.Permission_denied _) -> "Error.Permission_denied")
    in json

let do_metrics (id : int) : string =
  match get_handle id with
  | None -> error_json "Invalid runtime handle"
  | Some handle ->
    let snap = Par.Runtime.metrics_snapshot handle.rt in
    let pairs = List.map (fun (k, v) ->
      Printf.sprintf "\"%s\": %d" k v
    ) snap in
    Printf.sprintf "{\"status\": \"ok\", \"metrics\": {%s}}"
      (String.concat ", " pairs)

let do_steer (id : int) (message : string) : int =
  match get_handle id with
  | None -> -1
  | Some handle ->
    Par.Runtime.steer handle.rt message;
    0

let do_follow_up (id : int) (message : string) : int =
  match get_handle id with
  | None -> -1
  | Some handle ->
    Par.Runtime.follow_up handle.rt message;
    0

let () =
  Callback.register "par_health"
    (fun (rt_val : Obj.t) ->
      let id = Obj.magic rt_val in
      do_health id)

let () =
  Callback.register "par_metrics"
    (fun (rt_val : Obj.t) ->
      let id = Obj.magic rt_val in
      do_metrics id)

let () =
  Callback.register "par_steer"
    (fun (rt_val : Obj.t) (message : string) ->
      let id = Obj.magic rt_val in
      do_steer id message)

let () =
  Callback.register "par_follow_up"
    (fun (rt_val : Obj.t) (message : string) ->
      let id = Obj.magic rt_val in
      do_follow_up id message)

let () =
  Callback.register "par_mcp_server"
    (fun (rt_val : Obj.t) (server_id : string) ->
      let id = Obj.magic rt_val in
      unwrap (do_mcp_server id server_id))

let () =
  Callback.register "par_mcp_list_tools"
    (fun (rt_val : Obj.t) (server_id : string) ->
      let id = Obj.magic rt_val in
      unwrap (do_mcp_list_tools id server_id))

let () =
  Callback.register "par_workflow_status"
    (fun (rt_val : Obj.t) (run_id : string) ->
      let id = Obj.magic rt_val in
      unwrap (do_workflow_status id run_id))

let () =
  Callback.register "par_workflow_cancel"
    (fun (rt_val : Obj.t) (run_id : string) ->
      let id = Obj.magic rt_val in
      do_workflow_cancel id run_id)

let () =
  Callback.register "par_event_subscribe"
    (fun (rt_val : Obj.t) (cb_val : Obj.t) ->
      let id = Obj.magic rt_val in
      let cb = Obj.magic cb_val in
      do_event_subscribe id cb)

let () =
  Callback.register "par_version"
    (fun (_unit : Obj.t) ->
      Obj.repr (do_version ()))
