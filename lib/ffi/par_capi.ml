(* par_capi.ml — OCaml side of the C FFI bridge.
    Registers OCaml functions via Callback.register so C code can call them.
    Uses an Eio event loop thread to serialize all Runtime operations. *)

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
  ignore (Hashtbl.remove handles id)

let unwrap : string option -> Obj.t = function
  | Some v -> Obj.repr v
  | None -> Obj.repr "{\"error\": \"internal: no response from worker\"}"

let shutdown_flag = ref false

let do_init (config_json : string) =
  try
    let json = Yojson.Safe.from_string config_json in
    let config = match Par.Types.runtime_config_of_yojson json with
      | Ok c -> c
      | Error s -> failwith (Printf.sprintf "Invalid config JSON: %s" s)
    in
    let rt = Eio.Switch.run (fun sw ->
      match Par.Runtime.create ~config sw with
      | Ok r -> r
      | Error _ -> failwith "Runtime.create failed"
    ) in
    let handle = { rt } in
    let id = alloc_handle handle in
    Obj.repr id
  with e ->
    Obj.repr (error_json (Printexc.to_string e))

let do_shutdown (id : int) =
  match get_handle id with
  | None -> error_json "Invalid runtime handle"
  | Some handle ->
    shutdown_flag := true;
    (try ignore (Par.Runtime.close handle.rt) with _ -> ());
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
               let _tool = Par.Runtime.register_tool handle.rt
                 ~name ~description:desc
                 ~input_schema:json_schema
                 ~handler:(fun input _token ->
                   Logs.warn (fun m ->
                     m "FFI tool '%s': no-op handler invoked \
                        (Python callback not yet supported)" name);
                   Par.Types.Success input)
                 () in
               Obj.repr 0
          | _ -> Obj.repr (-2))
       with
       | Yojson.Json_error _ -> Obj.repr (-2)
       | _ -> Obj.repr (-1))

let do_register_agent (id : int) (_config_json : string) =
  match get_handle id with
  | None -> Obj.repr (-1)
  | Some handle ->
    ignore handle;
    Obj.repr (-1)

let do_invoke (id : int) (agent_id : string) (message : string) =
  match get_handle id with
  | None -> None
  | Some handle ->
    (try
       let result = Par.Runtime.invoke handle.rt
         ~agent_id ~message () in
       let json = match result with
         | Ok resp ->
           Printf.sprintf "{\"status\": \"ok\", \"content\": %s}"
             (Yojson.Safe.to_string (Par.Types.llm_response_to_yojson resp))
         | Error err ->
           error_json (Printf.sprintf "Invoke failed: %s"
             (Yojson.Safe.to_string (Par.Types.error_category_to_yojson err)))
       in
       Some json
     with e -> Some (error_json (Printexc.to_string e)))

let do_submit_workflow (id : int) (workflow_json : string) =
  match get_handle id with
  | None -> None
  | Some handle ->
    ignore handle;
    (try
       let _json = Yojson.Safe.from_string workflow_json in
       Some (error_json "submit_workflow from JSON: not yet fully implemented")
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
