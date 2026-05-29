(* par_capi.ml — OCaml side of the C FFI bridge.
    Registers OCaml functions via Callback.register so C code can call them.
    Actual implementations will be added in Wave 2-3. *)

let () =
  Callback.register "par_init" (fun (_config_json : string) ->
    failwith "par_init: not yet implemented")

let () =
  Callback.register "par_shutdown" (fun (_rt : Obj.t) ->
    failwith "par_shutdown: not yet implemented")

let () =
  Callback.register "par_register_tool"
    (fun (_rt : Obj.t) (_name : string) (_desc : string) (_schema : string) ->
      failwith "par_register_tool: not yet implemented")

let () =
  Callback.register "par_register_agent"
    (fun (_rt : Obj.t) (_config_json : string) ->
      failwith "par_register_agent: not yet implemented")

let () =
  Callback.register "par_invoke"
    (fun (_rt : Obj.t) (_agent_id : string) (_message : string) ->
      failwith "par_invoke: not yet implemented")

let () =
  Callback.register "par_submit_workflow"
    (fun (_rt : Obj.t) (_workflow_json : string) ->
      failwith "par_submit_workflow: not yet implemented")

let () =
  Callback.register "par_approve_workflow"
    (fun (_rt : Obj.t) (_run_id : string) (_approver : string) ->
      failwith "par_approve_workflow: not yet implemented")

let () =
  Callback.register "par_resume_workflow"
    (fun (_rt : Obj.t) (_run_id : string) ->
      failwith "par_resume_workflow: not yet implemented")
