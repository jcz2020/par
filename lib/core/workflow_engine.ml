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
  on_step_complete : (int list -> Yojson.Safe.t -> unit) option;
  workflow_run_id : Workflow_run_id.t option;
  workflow_id_resolver : unit -> string option;
  workspace : Workspace.workspace;
}

exception Workflow_suspended of {
  prompt : string;
  allowed_roles : string list;
  checkpoint : workflow_checkpoint;
}

let make_checkpoint ~step_path ?(step_results = []) ?(allowed_roles = None) ctx =
  let workflow_id =
    match ctx.workflow_id_resolver () with
    | Some id -> id
    | None -> ""
  in
  {
    workflow_id;
    step_path;
    variables = ctx.variables;
    step_results;
    allowed_roles;
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

let rec json_substitute (vars : (string * Yojson.Safe.t) list) (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `String s -> `String (substitute s vars)
  | `Assoc fields -> `Assoc (List.map (fun (k, v) -> (k, json_substitute vars v)) fields)
  | `List xs -> `List (List.map (json_substitute vars) xs)
  | other -> other

let rec flatten_json prefix (json : Yojson.Safe.t) : (string * Yojson.Safe.t) list =
  match json with
  | `Assoc fields ->
    List.concat_map (fun (k, v) ->
      let path = if prefix = "" then k else prefix ^ "." ^ k in
      match v with
      | `Assoc _ -> flatten_json path v
      | `List _ -> flatten_json path v
      | other -> [(path, other)]
    ) fields
  | `List items ->
    List.concat_map (fun (idx, item) ->
      let path = if prefix = "" then string_of_int idx else prefix ^ "." ^ string_of_int idx in
      flatten_json path item
    ) (List.mapi (fun i v -> (i, v)) items)
  | other -> if prefix = "" then [] else [(prefix, other)]

(* -------------------------------------------------------------------------- *)
(* Step execution — recursive dispatcher                                      *)
(* -------------------------------------------------------------------------- *)

let rec execute_step ?(path=[]) ctx step =
  Cancellation.check_cancel ctx.token;
  match step with
  | Agent_call { agent_id; prompt_template } ->
    (match ctx.agent_resolver agent_id with
     | None -> Result.Error (Invalid_input (Printf.sprintf "Agent not found: %s" agent_id))
     | Some agent ->
       let prompt = substitute prompt_template ctx.variables in
        match Engine.run_agent ctx.token agent prompt ctx.llm ctx.registry with
        | Ok (resp, _) ->
          let text_field = match resp.text with
            | Some t -> ("text", `String t)
            | None -> ("text", `Null) in
          let tool_calls_field = match resp.tool_calls with
            | Some tcs -> ("tool_calls", `List (List.map Types.tool_call_to_yojson tcs))
            | None -> ("tool_calls", `Null) in
          Ok (`Assoc [text_field; tool_calls_field])
        | Result.Error (err, _) -> Result.Error err)

  | Tool_call { tool_name; input } ->
    (match ctx.tool_resolver tool_name with
     | None -> Result.Error (Invalid_input (Printf.sprintf "Tool not found: %s" tool_name))
     | Some _ ->
       (match Tool_registry.resolve ctx.registry tool_name with
        | None -> Result.Error (Internal (Printf.sprintf "Tool handler not registered: %s" tool_name))
        | Some handler ->
           let substituted_input = json_substitute ctx.variables input in
           (match handler substituted_input ctx.token with
            | Success json -> Ok json
            | Types.Error { category; _ } -> Result.Error category
            | Types.Handoff _ -> Result.Error (Invalid_input "Handoff not supported in workflow step"))))

  | Sequential steps ->
    execute_sequential ~path ctx steps

  | Parallel steps ->
    execute_parallel ~path ctx steps

  | Conditional { condition; then_step; else_step } ->
    (match Expression.evaluate_to_bool ctx.variables condition with
     | Result.Error e -> Result.Error e
     | Ok true -> execute_step ~path ctx then_step
     | Ok false ->
       match else_step with
       | Some s -> execute_step ~path ctx s
       | None -> Ok `Null)

  | Map_reduce { over; step = inner_step; reduce } ->
    execute_map_reduce ~path ctx over inner_step reduce

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
            let checkpoint = make_checkpoint ~step_path:path
                               ~allowed_roles:(Some allowed_roles) ctx in
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

and execute_sequential ?(path=[]) ?(start_idx=0) ctx steps =
  (* §1.1 resume: start_idx offsets step_path and result_N bindings so resumed
     steps continue indexing from where the suspension occurred. Default 0. *)
  let rec loop acc idx acc_results = function
    | [] -> Ok (`List (List.rev acc))
    | step :: rest ->
      let effective_idx = start_idx + idx in
      let step_path = path @ [effective_idx] in
      let results_so_far = List.filter_map (fun (k, v) ->
        if k = "result" then Some v else None) acc_results in
      let effective_vars =
        ctx.variables @ acc_results
        @ [("results", `List (List.rev results_so_far))] in
      let step_ctx = { ctx with variables = effective_vars } in
      match execute_step ~path:step_path step_ctx step with
      | Ok result ->
        (match ctx.on_step_complete with
         | Some cb -> cb step_path result
         | None -> ());
        let flat = flatten_json "" result in
        let flat_with_prefix = ("result", result) ::
          List.map (fun (k, v) -> ("result." ^ k, v)) flat @
          [Printf.sprintf "result_%d" effective_idx, result] @
          List.map (fun (k, v) ->
            (Printf.sprintf "result_%d.%s" effective_idx k, v)) flat in
        loop (result :: acc) (idx + 1) (acc_results @ flat_with_prefix) rest
      | Result.Error err ->
        match ctx.failure_policy with
        | Fail_fast -> Result.Error err
        | Continue_on_failure ->
          (match ctx.on_step_complete with
           | Some cb -> cb step_path `Null
           | None -> ());
          let new_bindings = [
            ("result", `Null);
            (Printf.sprintf "result_%d" effective_idx, `Null);
          ] in
          loop acc (idx + 1) (acc_results @ new_bindings) rest
        | Conditional { on_failure } ->
          match execute_step ~path:step_path step_ctx on_failure with
          | Ok _ -> loop acc (idx + 1) acc_results rest
          | Result.Error e -> Result.Error e
  in
  loop [] 0 [] steps


(* -------------------------------------------------------------------------- *)
(* Parallel execution — Eio fibers with semaphore-limited concurrency         *)
(* -------------------------------------------------------------------------- *)

and execute_parallel ?(path=[]) ctx steps =
  let sem = Eio.Semaphore.make ctx.parallel_limit in
  let promises = List.mapi (fun idx step ->
    Eio.Fiber.fork_promise ~sw:ctx.token.switch (fun () ->
      Eio.Semaphore.acquire sem;
      Fun.protect
        ~finally:(fun () -> Eio.Semaphore.release sem)
        (fun () -> execute_step ~path:(path @ [idx]) ctx step)
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

and execute_map_reduce ?(path=[]) ctx over_var step reduce =
  match List.assoc_opt over_var ctx.variables with
  | None ->
    Result.Error (Invalid_input (Printf.sprintf "Map_reduce variable not found: %s" over_var))
  | Some (`List items) ->
    let indexed = List.mapi (fun idx item -> (idx, item)) items in
    let results = List.filter_map (fun (idx, item) ->
      let new_vars =
        (over_var, item) :: List.filter (fun (k, _) -> k <> over_var) ctx.variables
      in
      let inner_ctx = { ctx with variables = new_vars } in
      match execute_step ~path:(path @ [idx]) inner_ctx step with
      | Ok v -> Some v
      | Result.Error _ -> None
    ) indexed in
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
  match execute_step ~path:[] ctx wf.def.steps with
  | Ok value ->
    let elapsed = Unix.gettimeofday () -. start_time in
    let wf_result = {
      outputs = [ ("result", value) ];
      status = `Success;
      elapsed;
      metadata = [ ("workflow_id", wf.def.id); ("workflow_name", wf.def.name) ];
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
        metadata = [ ("workflow_id", wf.def.id); ("workflow_name", wf.def.name) ];
      } in
      (match wf.on_complete with Some cb -> cb wf_result | None -> ());
      Ok wf_result
    | Fail_fast | Conditional _ ->
      let wf_result = {
        outputs = [];
        status = `Failed;
        elapsed;
        metadata = [ ("workflow_id", wf.def.id); ("workflow_name", wf.def.name) ];
      } in
      (match wf.on_complete with Some cb -> cb wf_result | None -> ());
      Result.Error err

(* -------------------------------------------------------------------------- *)
(* Resume from checkpoint (§1.1) — re-enter execution at suspended step       *)
(* -------------------------------------------------------------------------- *)

let step_type_name = function
  | Agent_call _ -> "Agent_call"
  | Tool_call _ -> "Tool_call"
  | Parallel _ -> "Parallel"
  | Sequential _ -> "Sequential"
  | Conditional _ -> "Conditional"
  | Map_reduce _ -> "Map_reduce"
  | Human_approval _ -> "Human_approval"
  | Sub_workflow _ -> "Sub_workflow"

(* Variable restore is required because checkpoint.variables carries the
   accumulated result bindings from steps that completed before suspension. *)
let rec resume_from_checkpoint (ctx : exec_context) (wf_steps : workflow_step)
                                (checkpoint : workflow_checkpoint) =
  let ctx' = { ctx with variables = checkpoint.variables } in
  resume_step ~path:[] ctx' wf_steps checkpoint.step_path

and resume_step ~path (ctx : exec_context) (step : workflow_step) (step_path : int list) =
  match step_path with
  | [] ->
    (* At the suspended step itself. Must be Human_approval — treat as approved. *)
    (match step with
     | Human_approval _ -> Ok `Null
     | _ ->
       Result.Error (Internal
         (Printf.sprintf "resume: leaf step at path [%s] is %s, not Human_approval"
            (String.concat "." (List.map string_of_int path))
            (step_type_name step))))
  | idx :: rest ->
    (match step with
     | Sequential steps ->
       let rest_to_run =
         let rec skip n lst =
           if n <= 0 then lst
           else match lst with
             | _ :: tl -> skip (n - 1) tl
             | [] -> []
         in
         skip (idx + 1) steps
       in
       (match rest with
         | [] ->
           (match List.nth_opt steps idx with
            | None ->
              Result.Error (Internal
                (Printf.sprintf "resume: index %d out of bounds for Sequential at [%s]"
                   idx (String.concat "." (List.map string_of_int path))))
            | Some (Human_approval _) ->
              execute_sequential ~path ~start_idx:(idx + 1) ctx rest_to_run
            | Some other ->
              Result.Error (Internal
                (Printf.sprintf "resume: step at Sequential index %d (path [%s]) is %s, not Human_approval (only Human_approval can suspend)"
                   idx (String.concat "." (List.map string_of_int path))
                   (step_type_name other))))
         | _ :: _ ->
          (match List.nth_opt steps idx with
           | None ->
             Result.Error (Internal
               (Printf.sprintf "resume: index %d out of bounds for Sequential at [%s]"
                  idx (String.concat "." (List.map string_of_int path))))
           | Some target ->
             (match resume_step ~path:(path @ [idx]) ctx target rest with
              | Ok _ -> execute_sequential ~path ~start_idx:(idx + 1) ctx rest_to_run
              | Error e -> Error e)))
     | Conditional { condition; then_step; else_step } ->
        (match Expression.evaluate_to_bool ctx.variables condition with
         | Ok true ->
           (match resume_step ~path:(path @ [0]) ctx then_step rest with
            | Ok _ -> Ok `Null
            | Error e -> Error e)
         | Ok false ->
           (match else_step with
            | Some s ->
              (match resume_step ~path:(path @ [1]) ctx s rest with
               | Ok _ -> Ok `Null
               | Error e -> Error e)
            | None -> Ok `Null)
         | Error e -> Error e)
     | Parallel _ | Map_reduce _ ->
       Result.Error (Internal
         (Printf.sprintf "Resume not supported for %s at step_path [%s] (only Sequential + Conditional)"
            (step_type_name step)
            (String.concat "." (List.map string_of_int (path @ step_path)))))
     | Agent_call _ | Tool_call _ | Human_approval _ | Sub_workflow _ ->
       Result.Error (Internal
         (Printf.sprintf "resume: leaf step %s at non-empty step_path [%s]"
            (step_type_name step)
            (String.concat "." (List.map string_of_int (path @ step_path))))))
