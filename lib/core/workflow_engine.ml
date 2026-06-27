open Types

(* -------------------------------------------------------------------------- *)
(* Workflow engine — approval deadline tracking                         *)
(* -------------------------------------------------------------------------- *)

module Approval_deadline = struct
  type t = {
    deadline : float;
    switch : Eio.Switch.t;
  }
  let table : (Workflow_run_id.t, t) protected_hashtbl = {
    data = Hashtbl.create 16;
    mutex = Eio.Mutex.create ();
  }

  let record run_id ~deadline ~switch =
    htbl_set table run_id { deadline; switch }

  let lookup run_id =
    htbl_get table run_id

  let deadline_of t = t.deadline

  let switch_of t = t.switch

  let remove run_id =
    htbl_remove table run_id
end

(* -------------------------------------------------------------------------- *)
(* Workflow engine — execution context                                  *)
(* -------------------------------------------------------------------------- *)

type exec_context = {
  variables : (string * Yojson.Safe.t) list;
  token : cancellation_token;
  agent_resolver : string -> agent_config option;
  tool_resolver : string -> tool_descriptor option;
  llm : llm_service;
  registry : Tool_registry.t;
  parallel_limit : int;
  failure_policy : failure_policy;
  workflow_resolver : string -> workflow option;
  on_step_complete : (string -> Yojson.Safe.t -> unit) option;
  workflow_run_id : Workflow_run_id.t option;
}

exception Workflow_suspended of {
  prompt : string;
  allowed_roles : string list;
  checkpoint : workflow_checkpoint;
}

let make_checkpoint ?(step_path = []) ?(step_results = []) ctx =
  {
    step_path;
    variables = ctx.variables;
    step_results;
  }

(* -------------------------------------------------------------------------- *)
(* Variable substitution — replace {{key}} with JSON value in template        *)
(* -------------------------------------------------------------------------- *)

let json_value_to_string = function
  | `String s -> s
  | `Int n -> string_of_int n
  | `Float f -> string_of_float f
  | `Bool b -> string_of_bool b
  | `Null -> ""
  | json -> Yojson.Safe.pretty_to_string json

let substitute template vars =
  List.fold_left (fun acc (key, value) ->
    let placeholder = Printf.sprintf "{{%s}}" key in
    Str.global_replace (Str.regexp_string placeholder)
      (json_value_to_string value) acc
  ) template vars

(* -------------------------------------------------------------------------- *)
(* Step execution — recursive dispatcher                                      *)
(* -------------------------------------------------------------------------- *)

let rec execute_step ctx step =
  Cancellation.check_cancel ctx.token;
  match step with
  | Agent_call { agent_id; prompt_template } ->
    (match ctx.agent_resolver agent_id with
     | None -> Result.Error (Invalid_input (Printf.sprintf "Agent not found: %s" agent_id))
     | Some agent ->
       let prompt = substitute prompt_template ctx.variables in
        match Engine.run_agent ctx.token agent prompt ctx.llm ctx.registry with
        | Ok (resp, _) -> Ok (match resp.text with Some t -> `String t | None -> `Null)
        | Result.Error (err, _) -> Result.Error err)

  | Tool_call { tool_name; input } ->
    (match ctx.tool_resolver tool_name with
     | None -> Result.Error (Invalid_input (Printf.sprintf "Tool not found: %s" tool_name))
     | Some _ ->
       (match Tool_registry.resolve ctx.registry tool_name with
        | None -> Result.Error (Internal (Printf.sprintf "Tool handler not registered: %s" tool_name))
        | Some handler ->
           (match handler input ctx.token with
            | Success json -> Ok json
            | Types.Error { category; _ } -> Result.Error category
            | Types.Handoff _ -> Result.Error (Invalid_input "Handoff not supported in workflow step"))))

  | Sequential steps ->
    execute_sequential ctx steps

  | Parallel steps ->
    execute_parallel ctx steps

  | Conditional { condition; then_step; else_step } ->
    (match Expression.evaluate_to_bool ctx.variables condition with
     | Result.Error e -> Result.Error e
     | Ok true -> execute_step ctx then_step
     | Ok false ->
       match else_step with
       | Some s -> execute_step ctx s
       | None -> Ok `Null)

  | Map_reduce { over; step = inner_step; reduce } ->
    execute_map_reduce ctx over inner_step reduce

  | Human_approval { prompt_template; timeout; allowed_roles } ->
    let prompt = substitute prompt_template ctx.variables in
    (match ctx.workflow_run_id with
     | None -> Ok (`Bool true)
     | Some run_id ->
       let timeout_secs = timeout in
       Approval_deadline.record run_id
         ~deadline:(Unix.gettimeofday () +. timeout_secs)
         ~switch:ctx.token.switch;
        let suspension_ref : (string * string list * workflow_checkpoint) option ref = ref None in
        Eio.Fiber.first
          (fun () ->
            let checkpoint = make_checkpoint ctx in
            suspension_ref := Some (prompt, allowed_roles, checkpoint))
          (fun () ->
            let deadline = Unix.gettimeofday () +. timeout_secs in
            while Unix.gettimeofday () < deadline
                  && Option.is_none !suspension_ref
                  && not ctx.token.cancelled do
              Eio.Fiber.yield ()
            done);
        Approval_deadline.remove run_id;
        match !suspension_ref with
        | Some (p, roles, cp) -> raise (Workflow_suspended { prompt = p; allowed_roles = roles; checkpoint = cp })
        | None ->
         if ctx.token.cancelled then
           Result.Error (Internal "Cancelled during human approval")
          else
            Result.Error (Timeout))

   | Sub_workflow { workflow_id; variables } ->
    (match ctx.workflow_resolver workflow_id with
     | None ->
       Result.Error (Invalid_input (Printf.sprintf "Sub-workflow not found: %s" workflow_id))
     | Some child_wf ->
       let merged_vars = variables @ ctx.variables in
       let child_ctx = { ctx with variables = merged_vars } in
       (match execute_workflow child_ctx child_wf with
        | Ok wf_result ->
          (match List.assoc_opt "result" wf_result.outputs with
           | Some v -> Ok v
           | None -> Ok `Null)
        | Error err -> Error err))

(* -------------------------------------------------------------------------- *)
(* Sequential execution — left-to-right, respects failure_policy              *)
(* -------------------------------------------------------------------------- *)

and execute_sequential ctx steps =
  let rec loop acc idx = function
    | [] -> Ok (`List (List.rev acc))
    | step :: rest ->
      match execute_step ctx step with
      | Ok result ->
        (match ctx.on_step_complete with
         | Some cb -> cb (string_of_int idx) result
         | None -> ());
        loop (result :: acc) (idx + 1) rest
      | Result.Error err ->
        match ctx.failure_policy with
        | Fail_fast -> Result.Error err
        | Continue_on_failure ->
          (match ctx.on_step_complete with
           | Some cb -> cb (string_of_int idx) `Null
           | None -> ());
          loop acc (idx + 1) rest
        | Conditional { on_failure } ->
          match execute_step ctx on_failure with
          | Ok _ -> loop acc (idx + 1) rest
          | Result.Error e -> Result.Error e
  in
  loop [] 0 steps

(* -------------------------------------------------------------------------- *)
(* Parallel execution — Eio fibers with semaphore-limited concurrency         *)
(* -------------------------------------------------------------------------- *)

and execute_parallel ctx steps =
  let sem = Eio.Semaphore.make ctx.parallel_limit in
  let promises = List.map (fun step ->
    Eio.Fiber.fork_promise ~sw:ctx.token.switch (fun () ->
      Eio.Semaphore.acquire sem;
      Fun.protect
        ~finally:(fun () -> Eio.Semaphore.release sem)
        (fun () -> execute_step ctx step)
    )
  ) steps in
  let results = List.map (fun p ->
    match Eio.Promise.await p with
    | Ok r -> r
    | Error ex -> Result.Error (Internal (Printexc.to_string ex))
  ) promises in
  let successes = List.filter_map (function Ok v -> Some v | Result.Error _ -> None) results in
  let has_error = List.exists (function Result.Error _ -> true | Ok _ -> false) results in
  if has_error then
    match ctx.failure_policy with
    | Fail_fast ->
      (match List.find_map (function Result.Error e -> Some e | Ok _ -> None) results with
       | Some e -> Result.Error e
       | None -> Ok (`List successes))
    | Continue_on_failure ->
      Ok (`List successes)
    | Conditional { on_failure } ->
      match execute_step ctx on_failure with
      | Ok _ -> Ok (`List successes)
      | Result.Error e -> Result.Error e
  else
    Ok (`List successes)

(* -------------------------------------------------------------------------- *)
(* Map-reduce execution — iterate over JSON array, apply reduce strategy      *)
(* -------------------------------------------------------------------------- *)

and execute_map_reduce ctx over_var step reduce =
  match List.assoc_opt over_var ctx.variables with
  | None ->
    Result.Error (Invalid_input (Printf.sprintf "Map_reduce variable not found: %s" over_var))
  | Some (`List items) ->
    let results = List.filter_map (fun item ->
      let new_vars =
        (over_var, item) :: List.filter (fun (k, _) -> k <> over_var) ctx.variables
      in
      let inner_ctx = { ctx with variables = new_vars } in
      match execute_step inner_ctx step with
      | Ok v -> Some v
      | Result.Error _ -> None
    ) items in
    apply_reduce reduce results
  | Some _ ->
    Result.Error (Invalid_input (Printf.sprintf "Map_reduce variable is not an array: %s" over_var))

and apply_reduce reduce results =
  match reduce with
  | `Collect_all -> Ok (`List results)
  | `First_success ->
    (match results with
     | first :: _ -> Ok first
     | [] -> Result.Error (Internal "Map_reduce First_success: no successful results"))
  | `Majority ->
    (match results with
     | [] -> Ok `Null
     | _ ->
       let rec count x = function
         | [] -> 0
         | y :: rest when Yojson.Safe.equal x y -> 1 + count x rest
         | _ :: rest -> count x rest
       in
       let rec find_majority best best_count = function
         | [] -> best
         | x :: rest ->
           let c = count x results in
           if c > best_count then find_majority x c rest
           else find_majority best best_count rest
       in
       match results with
       | first :: rest -> Ok (find_majority first (count first results) rest)
       | [] -> Ok `Null)

(* -------------------------------------------------------------------------- *)
(* Top-level workflow execution                                               *)
(* -------------------------------------------------------------------------- *)

and execute_workflow ctx wf =
  let start_time = Unix.gettimeofday () in
  match execute_step ctx wf.steps with
  | Ok value ->
    let elapsed = Unix.gettimeofday () -. start_time in
    let wf_result = {
      outputs = [ ("result", value) ];
      status = `Success;
      elapsed;
      metadata = [ ("workflow_id", wf.id); ("workflow_name", wf.name) ];
    } in
    (match wf.on_complete with Some cb -> cb wf_result | None -> ());
    Ok wf_result
  | Result.Error err ->
    let elapsed = Unix.gettimeofday () -. start_time in
    match ctx.failure_policy with
    | Continue_on_failure ->
      let wf_result = {
        outputs = [];
        status = `Partial;
        elapsed;
        metadata = [ ("workflow_id", wf.id); ("workflow_name", wf.name) ];
      } in
      (match wf.on_complete with Some cb -> cb wf_result | None -> ());
      Ok wf_result
    | Fail_fast | Conditional _ ->
      let wf_result = {
        outputs = [];
        status = `Failed;
        elapsed;
        metadata = [ ("workflow_id", wf.id); ("workflow_name", wf.name) ];
      } in
      (match wf.on_complete with Some cb -> cb wf_result | None -> ());
      Result.Error err
