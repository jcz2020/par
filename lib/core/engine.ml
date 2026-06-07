open Types

(* -------------------------------------------------------------------------- *)
(* Middleware chain — Russian Doll composition                           *)
(* -------------------------------------------------------------------------- *)

let apply_before_llm hooks conv next =
  List.fold_right (fun hook acc ->
    fun c ->
      match hook.on_before_llm with
      | Some f ->
        (match f c with Some c' -> acc c' | None -> acc c)
      | None -> acc c
  ) hooks next conv

let apply_after_llm hooks resp next =
  List.fold_right (fun hook acc ->
    fun r ->
      match hook.on_after_llm with
      | Some f ->
        (match f r with Some r' -> acc r' | None -> acc r)
      | None -> acc r
  ) hooks next resp

let apply_before_tool hooks call next =
  List.fold_right (fun hook acc ->
    fun c ->
      match hook.on_before_tool with
      | Some f ->
        (match f c with Some c' -> acc c' | None -> acc c)
      | None -> acc c
  ) hooks next call

let apply_after_tool hooks (call, result) next =
  List.fold_right (fun hook acc ->
    fun (c, r) ->
      match hook.on_after_tool with
      | Some f ->
        (match f (c, r) with Some r' -> acc (c, r') | None -> acc (c, r))
      | None -> acc (c, r)
  ) hooks next (call, result)

let apply_on_error hooks _conv err next =
  List.fold_right (fun hook acc ->
    fun e ->
      match hook.on_error with
      | Some f ->
        (match f e with Some r -> r | None -> acc e)
      | None -> acc e
  ) hooks next err

(* -------------------------------------------------------------------------- *)
(* Tool pipeline                                                         *)
(* -------------------------------------------------------------------------- *)

let find_tool (agent : agent_config) tool_name =
  List.find_opt (fun (td : tool_descriptor) -> td.name = tool_name) agent.tools

let execute_tool (token : cancellation_token) (descriptor : tool_descriptor)
    handler input middleware on_progress =
  match Validation.validate_tool_input_result descriptor.input_schema input with
  | Error category ->
    let message = match category with
      | Types.Invalid_input msg -> "Schema mismatch: " ^ msg
      | _ -> "Schema validation failed"
    in
    Error {
      category;
      message;
      retryable = false;
      metadata = [];
    }
  | Ok () ->
    let (call : tool_call) = {
      id = Task_id.to_string (Task_id.create ());
      name = descriptor.name;
      arguments = input
    } in
    let progress msg =
      (match descriptor.on_update with
       | Some cb -> cb msg
       | None -> ());
      (match on_progress with
       | Some pub -> pub msg
       | None -> ())
    in
    progress (Printf.sprintf "Starting tool %s" descriptor.name);
    apply_before_tool middleware call (fun (call' : tool_call) ->
      let result = handler input token in
      (match result with
       | Success _ -> progress (Printf.sprintf "Tool %s succeeded" descriptor.name)
       | Error _ -> progress (Printf.sprintf "Tool %s failed" descriptor.name));
      apply_after_tool middleware (call', result) (fun ((_:tool_call), res) ->
        res
      )
    )

(* -------------------------------------------------------------------------- *)
(* Agent executor — ReAct loop                                           *)
(* -------------------------------------------------------------------------- *)

let make_conversation system_prompt user_message =
  let sys = { role = System; content = Some system_prompt; tool_calls = None; tool_call_id = None; name = None } in
  let usr = { role = User; content = Some user_message; tool_calls = None; tool_call_id = None; name = None } in
  { messages = [ sys; usr ]; metadata = [] }

let add_assistant_message conv resp =
  let msg = {
    role = Assistant;
    content = resp.text;
    tool_calls = resp.tool_calls;
    tool_call_id = None;
    name = None;
  } in
  { conv with messages = conv.messages @ [ msg ] }

let add_tool_result_message conv (call : tool_call) result =
  let content = match result with
    | Success json -> Yojson.Safe.to_string json
    | Error e -> e.message
  in
  let msg = {
    role = Tool;
    content = Some content;
    tool_calls = None;
    tool_call_id = Some call.id;
    name = Some call.name;
  } in
  { conv with messages = conv.messages @ [ msg ] }

let run_agent ?(runtime_id = "unknown") ?(steering = None) ?(followup = None)
    ?(tool_call_hooks = None) ?(quota = None) ?(parallel = false)
    ?(on_progress = None) ?(on_tool_event = None)
    ?conversation token agent user_message llm registry =
  let sys_prompt = match Template.effective_system_prompt agent ~runtime_id with
    | Ok s -> s
    | Error e ->
      let msg = match e with
        | Types.Invalid_input m -> m
        | Types.Internal m -> m
        | _ -> "render failed"
      in
      Logs.warn (fun m ->
        m "Template render failed, falling back to plain system_prompt: %s" msg);
      agent.system_prompt
  in
  let drain_into_conv conv queue =
    match queue with
    | None -> conv
    | Some q ->
      let msgs = Steering_queue.drain_all q in
      List.fold_left (fun c msg ->
        let usr = { role = User; content = Some msg; tool_calls = None;
                    tool_call_id = None; name = None } in
        { c with messages = c.messages @ [usr] }
      ) conv msgs
  in
  let log_message i msg =
    let role_str = match msg.role with
      | System -> "system" | User -> "user" | Assistant -> "assistant" | Tool -> "tool"
    in
    Logs.debug (fun m -> m "[engine]   msg[%d]: role=%s content=%s"
      i role_str
      (match msg.content with Some c -> c | None -> "<none>"))
  in
  let rec loop conv iterations =
    if iterations >= agent.max_iterations then
      Result.Error (Internal "Max iterations exceeded", conv)
    else begin
      Cancellation.check_cancel token;
      let conv = match agent.context_strategy with
        | None -> conv
        | Some strategy ->
          (match Context_manager.apply_strategy strategy conv (Some llm) with
           | Ok conv' -> conv'
           | Error _ -> conv)
      in
      let conv = apply_before_llm agent.middleware conv (fun c -> c) in
      Logs.info (fun m -> m "[engine] LLM call iter=%d: %d messages, agent=%s model=%s"
        iterations (List.length conv.messages) agent.id agent.model.model_name);
      List.iteri log_message conv.messages;
      match llm.complete_fn agent.model agent.tools conv with
      | Result.Error err ->
        let action = apply_on_error agent.middleware conv err
          (fun e -> Error { category = e; message = "LLM error"; retryable = false; metadata = [] })
        in
        (match action with
         | Error { retryable = true; _ } -> loop conv iterations
         | _ -> Result.Error (err, conv))
       | Ok resp ->
        let resp = apply_after_llm agent.middleware resp (fun r -> r) in
        Logs.info (fun m -> m "[engine] LLM response iter=%d: finish=%s text_len=%d tool_calls=%s"
          iterations
          (match resp.finish_reason with Stop -> "stop" | Tool_calls -> "tool_calls"
           | Max_tokens -> "max_tokens" | Content_filter -> "content_filter")
          (match resp.text with Some t -> String.length t | None -> 0)
          (match resp.tool_calls with Some tcs -> string_of_int (List.length tcs) | None -> "none"));
        match resp.tool_calls with
        | Some calls when calls <> [] ->
          let conv = add_assistant_message conv resp in
          (* 3-phase execution: preflight (serial) → execute → finalize (serial).
             When parallel_tool_execution is enabled, tools in a batch run via
             Eio.Fiber.fork_promise. One tool failure does NOT cancel others.
             With current sequential implementation, behavior is identical but
             slower. The parallel path requires a per-batch Eio.Switch which
             is set up by the runtime on invoke. *)
          (* Acquire/track per-tool semaphore to enforce max_concurrent_tasks quota.
             When parallel=true, the outer forking gives every tool a chance to run
             concurrently; the semaphore caps how many can be in-flight at once. *)
          let invoke_one (call : tool_call) : (tool_call * handler_result) =
            let call_with_id = { call with id = Task_id.to_string (Task_id.create ()) } in
            let event_task_id = Task_id.create () in
            let event_tool_name = call.name in
            let fire evt = match on_tool_event with
              | Some pub -> pub evt
              | None -> ()
            in
            fire (Tool_invoked { task_id = event_task_id; tool_name = event_tool_name });
            let start_t = Unix.gettimeofday () in
            let hook_result = (match tool_call_hooks with
              | Some hooks ->
                let ctx = { Hook.tool_name = call.name;
                            tool_call_id = call_with_id.id;
                            input = call.arguments;
                            has_ui = false } in
                Hook.run_chain hooks ctx
              | None -> Hook.Final_allow) in
            let invoke_allow original_input =
              match find_tool agent call.name with
              | None -> (call_with_id, Error {
                  category = Types.Invalid_input (Printf.sprintf "Tool not found: %s" call.name);
                  message = "Tool not found";
                  retryable = false;
                  metadata = []; })
              | Some descriptor -> (match Tool_registry.resolve registry call.name with
                  | None -> (call_with_id, Error {
                      category = Types.Internal (Printf.sprintf "Tool handler not registered: %s" call.name);
                      message = "Handler not registered";
                      retryable = false;
                      metadata = []; })
                  | Some handler -> (call_with_id, execute_tool token descriptor handler original_input agent.middleware on_progress))
            in
            let invoke_with_quota body =
              match quota with
              | Some sem ->
                Eio.Semaphore.acquire sem;
                Fun.protect body ~finally:(fun () -> Eio.Semaphore.release sem)
              | None -> body ()
            in
            let result = match hook_result with
              | Hook.Final_block reason -> (call_with_id, Error {
                  category = Types.Permission_denied (Printf.sprintf "tool '%s'" call.name);
                  message = Printf.sprintf "Blocked by hook: %s" reason;
                  retryable = false;
                  metadata = []; })
              | Hook.Final_modify modified_input ->
                invoke_with_quota (fun () -> invoke_allow modified_input)
              | Hook.Final_allow ->
                invoke_with_quota (fun () -> invoke_allow call.arguments) in
            let duration_ms = (Unix.gettimeofday () -. start_t) *. 1000.0 in
            (match result with
             | _, Success _ ->
               fire (Tool_completed { task_id = event_task_id;
                                      tool_name = event_tool_name;
                                      duration_ms })
             | _, Error { category; _ } ->
               fire (Tool_failed { task_id = event_task_id;
                                   tool_name = event_tool_name;
                                   error = category }));
            result in
          let results : (tool_call * handler_result) list =
            if parallel then
              let promises = List.map (fun (call : tool_call) ->
                Eio.Fiber.fork_promise ~sw:token.switch
                  (fun () -> invoke_one call)
              ) calls in
              List.map Eio.Promise.await_exn promises
            else
              List.map invoke_one calls
          in
          let conv = List.fold_left (fun conv ((call:tool_call), result) ->
            add_tool_result_message conv call result
          ) conv results in
          let conv = drain_into_conv conv steering in
          loop conv (iterations + 1)
        | _ ->
          match resp.finish_reason with
          | Max_tokens ->
            if iterations + 1 >= agent.max_iterations then Result.Error (Internal "Max iterations exceeded", conv)
            else loop conv (iterations + 1)
          | _ ->
            let conv = drain_into_conv conv followup in
            if Steering_queue.has_items (Option.value followup ~default:(Steering_queue.create ())) then
              loop conv (iterations + 1)
            else
              Ok (resp, conv)
     end
   in
  let conv = match conversation with
    | Some existing ->
      Logs.info (fun m -> m "[engine] Resuming conversation: %d existing messages, appending user message (%d chars)"
        (List.length existing.messages) (String.length user_message));
      let usr = { role = User; content = Some user_message; tool_calls = None;
                  tool_call_id = None; name = None } in
      { existing with messages = existing.messages @ [ usr ] }
    | None ->
      Logs.info (fun m -> m "[engine] New conversation: system_prompt=%d chars, user_message=%d chars"
        (String.length sys_prompt) (String.length user_message));
      make_conversation sys_prompt user_message
  in
  loop conv 0
