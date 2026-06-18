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
    handler input middleware on_progress ~tool_call_id =
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
      id = tool_call_id;
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
      let result =
        try handler input token
        with ex ->
          Logs.err (fun m -> m "[engine] tool %s raised: %s"
                       descriptor.name (Printexc.to_string ex));
          Error {
            category = Internal (Printf.sprintf "tool %s raised: %s"
                        descriptor.name (Printexc.to_string ex));
            message = Printf.sprintf "Tool handler crashed: %s" (Printexc.to_string ex);
            retryable = false;
            metadata = [];
          }
      in
      let result = match result with
       | Success output ->
        (match descriptor.output_schema with
         | Some schema ->
          (match Validation.validate_tool_input_result schema output with
           | Ok () -> result
           | Error category ->
            Error {
             category;
             message = Printf.sprintf
               "Tool '%s' output failed schema validation" descriptor.name;
             retryable = false;
             metadata = [("output_schema_violation", `Bool true)];
            })
         | None -> result)
       | Error _ -> result
       | Handoff _ -> result
      in
      (match result with
       | Success _ -> progress (Printf.sprintf "Tool %s succeeded" descriptor.name)
       | Error _ -> progress (Printf.sprintf "Tool %s failed" descriptor.name)
       | Handoff _ -> progress (Printf.sprintf "Tool %s handoff" descriptor.name));
      apply_after_tool middleware (call', result) (fun ((_:tool_call), res) ->
        res
      )
    )

(* -------------------------------------------------------------------------- *)
(* Agent executor — ReAct loop                                           *)
(* -------------------------------------------------------------------------- *)

let run_llm_with_optional_streaming llm agent_model agent_tools conv user_cb =
  match user_cb with
  | None -> llm.complete_fn agent_model agent_tools conv
  | Some user_chunk ->
    let text_buf = Buffer.create 256 in
    let tc_state : (string, (string * Buffer.t)) Hashtbl.t = Hashtbl.create 4 in
    let acc chunk =
      user_chunk chunk;
      match chunk with
      | Text_delta { text } -> Buffer.add_string text_buf text
      | Tool_call_start { tool_call_id; name } ->
        Hashtbl.replace tc_state tool_call_id (name, Buffer.create 64)
      | Tool_call_delta { tool_call_id; args_json } ->
        (match Hashtbl.find_opt tc_state tool_call_id with
         | Some (_, buf) -> Buffer.add_string buf args_json
         | None -> ())
      | Usage_update _ | Done _ -> ()
    in
    let stream_cfg : stream_config = { chunk_timeout = 30.0; total_timeout = None; buffer_size = 4096 } in
    match llm.stream_fn agent_model agent_tools conv stream_cfg acc with
    | Error _ as e -> e
    | Ok stream_complete ->
      let entries = Hashtbl.fold (fun id (name, buf) acc ->
        (id, name, Buffer.contents buf) :: acc) tc_state [] in
      let tool_calls = if entries = [] then None else
        Some (List.map (fun (id, name, args_str) ->
          let arguments = try Yojson.Safe.from_string args_str with _ -> `Null in
          { id; name; arguments }) entries) in
      let text = if Buffer.length text_buf = 0 then None else Some (Buffer.contents text_buf) in
      Ok { text; tool_calls; finish_reason = stream_complete.finish_reason;
           usage = stream_complete.final_usage; model = agent_model.model_name }

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
    | Handoff _ -> "<handoff>"
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
    ?(on_progress = None) ?(on_tool_event = None) ?(on_chunk = None)
    ?conversation ?agent_resolver ?(enable_handoff = false)
    token agent user_message llm registry =
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
  let rec loop ~agent ~global_max conv iterations =
    let global_max = max global_max agent.max_iterations in
    if iterations >= global_max then
      Result.Error (Internal "Max iterations exceeded", conv)
    else begin
      Cancellation.check_cancel token;
      let conv = match agent.context_strategy with
        | None -> conv
        | Some strategy ->
          (match Context_manager.apply_strategy strategy conv (Some llm) ~on_event:on_tool_event with
           | Ok conv' -> conv'
           | Error _ -> conv)
      in
      let conv = apply_before_llm agent.middleware conv (fun c -> c) in
      Logs.info (fun m -> m "[engine] LLM call iter=%d: %d messages, agent=%s model=%s"
        iterations (List.length conv.messages) agent.id agent.model.model_name);
      List.iteri log_message conv.messages;
      let llm_task_id = Task_id.create () in
      let fire_llm evt = match on_tool_event with
        | Some pub -> pub evt
        | None -> ()
      in
      fire_llm (Llm_request_sent { task_id = llm_task_id; model = agent.model.model_name });
      match run_llm_with_optional_streaming llm agent.model agent.tools conv on_chunk with
      | Result.Error err ->
        let action = apply_on_error agent.middleware conv err
          (fun e -> Error { category = e; message = "LLM error"; retryable = false; metadata = [] })
        in
        (match action with
         | Error { retryable = true; _ } -> loop ~agent ~global_max conv iterations
         | Handoff _ -> Result.Error (Internal "Handoff reached retry path", conv)
         | _ -> Result.Error (err, conv))
       | Ok resp ->
        fire_llm (Llm_response_received { task_id = llm_task_id; usage = resp.usage });
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
                            tool_call_id = call.id;
                            input = call.arguments;
                            has_ui = false } in
                Hook.run_chain hooks ctx
              | None -> Hook.Final_allow) in
            let invoke_allow original_input =
              match find_tool agent call.name with
              | None -> (call, Error {
                  category = Types.Invalid_input (Printf.sprintf "Tool not found: %s" call.name);
                  message = "Tool not found";
                  retryable = false;
                  metadata = []; })
              | Some descriptor -> (match Tool_registry.resolve registry call.name with
                  | None -> (call, Error {
                      category = Types.Internal (Printf.sprintf "Tool handler not registered: %s" call.name);
                      message = "Handler not registered";
                      retryable = false;
                      metadata = []; })
                  | Some handler -> (call, execute_tool token descriptor handler original_input agent.middleware on_progress ~tool_call_id:call.id))
            in
            let invoke_with_quota body =
              match quota with
              | Some sem ->
                Eio.Semaphore.acquire sem;
                Fun.protect body ~finally:(fun () -> Eio.Semaphore.release sem)
              | None -> body ()
            in
            let result = match hook_result with
              | Hook.Final_block reason -> (call, Error {
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
             | _, Success output ->
               let preview =
                 let s = Yojson.Safe.to_string output in
                 if String.length s > 500 then
                   Some (String.sub s 0 500 ^
                         Printf.sprintf "... (%d bytes total)" (String.length s))
                 else Some s
               in
               fire (Tool_completed { task_id = event_task_id;
                                      tool_name = event_tool_name;
                                      duration_ms;
                                      result_preview = preview })
             | _, Error { category; _ } ->
               fire (Tool_failed { task_id = event_task_id;
                                   tool_name = event_tool_name;
                                   error = category })
             | _, Handoff _ ->
               fire (Tool_completed { task_id = event_task_id;
                                      tool_name = event_tool_name;
                                      duration_ms;
                                      result_preview = None }));
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
          let (non_handoff, handoffs) =
            List.partition (fun (_, r) ->
              match r with Handoff _ -> false | _ -> true) results in
          let conv = List.fold_left (fun conv (c, r) ->
            add_tool_result_message conv c r) conv non_handoff in
          let conv = drain_into_conv conv steering in
          let execute_handoff (call : tool_call) target_agent_id carry_context task =
            let resolver = match agent_resolver with
              | Some r -> r
              | None -> (fun _ -> None)
            in
            match resolver target_agent_id with
            | None ->
              Result.Error (Invalid_input
                (Printf.sprintf "Handoff target not found: %s" target_agent_id), conv)
            | Some target_agent ->
              (match on_tool_event with
               | Some pub ->
                 let task_id = match Task_id.of_string call.id with
                   | Ok tid -> tid
                   | Error _ -> Task_id.create ()
                 in
                 pub (Agent_handoff {
                   from_agent = agent.id;
                   to_agent = target_agent_id;
                   task_id;
                 })
               | None -> ());
              let target_sys_prompt =
                match Template.effective_system_prompt target_agent ~runtime_id with
                | Ok s -> s
                | Error _ -> target_agent.system_prompt
              in
              (match carry_context with
               | true ->
                 let non_sys = List.filter
                   (fun (m : message) -> m.role <> System) conv.messages in
                 let sys_msg = {
                   role = System; content = Some target_sys_prompt;
                   tool_calls = None; tool_call_id = None; name = None
                 } in
                 let new_conv = { conv with messages = sys_msg :: non_sys } in
                 loop ~agent:target_agent ~global_max new_conv (iterations + 1)
               | false ->
                 (match task with
                  | Some t ->
                    let sys_msg = {
                      role = System; content = Some target_sys_prompt;
                      tool_calls = None; tool_call_id = None; name = None
                    } in
                    let user_msg = {
                      role = User; content = Some t;
                      tool_calls = None; tool_call_id = None; name = None
                    } in
                    let new_conv = { messages = [sys_msg; user_msg]; metadata = [] } in
                    loop ~agent:target_agent ~global_max new_conv (iterations + 1)
                  | None ->
                    Result.Error (Invalid_input
                      "Handoff with carry_context=false requires a task", conv)))
          in
          (match handoffs with
           | [] ->
             loop ~agent ~global_max conv (iterations + 1)
           | [(call, Handoff { target_agent_id; carry_context; task })] ->
             if not enable_handoff then
               Result.Error (Invalid_input
                 "Tool returned Handoff but enable_handoff=false", conv)
             else
               execute_handoff call target_agent_id carry_context task
           | [_] ->
             Result.Error (Internal
               "Non-Handoff result in handoffs partition", conv)
           | _ ->
             Result.Error (Invalid_input
               "Multiple handoffs in one tool batch", conv))
        | _ ->
          match resp.finish_reason with
          | Max_tokens ->
            if iterations + 1 >= global_max then Result.Error (Internal "Max iterations exceeded", conv)
            else loop ~agent ~global_max conv (iterations + 1)
          | _ ->
            let conv = drain_into_conv conv followup in
            if Steering_queue.has_items (Option.value followup ~default:(Steering_queue.create ())) then
              loop ~agent ~global_max conv (iterations + 1)
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
  loop ~agent ~global_max:0 conv 0
