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

let apply_on_error hooks conv err next =
  List.fold_right (fun hook acc ->
    fun e ->
      match hook.on_error with
      | Some f ->
        (match f conv e with Some r -> r | None -> acc e)
      | None -> acc e
  ) hooks next err

(* -------------------------------------------------------------------------- *)
(* Tool pipeline                                                         *)
(* -------------------------------------------------------------------------- *)

let find_tool (agent : agent_config) tool_name =
  List.find_opt (fun (td : tool_descriptor) -> td.name = tool_name) agent.tools

let execute_tool (token : cancellation_token) (descriptor : tool_descriptor)
    handler input middleware on_progress ~tool_call_id ~tool_timeout =
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
        try
          match tool_timeout with
          | Some seconds ->
            (match Cancellation.with_timeout seconds token (fun tok -> handler input tok) with
             | Ok r -> r
             | Error `Timeout ->
               Logs.warn (fun m -> m
                 "[engine] tool %s timed out after %gs"
                 descriptor.name seconds);
               Error {
                 category = Timeout;
                 message = Printf.sprintf
                   "Tool '%s' exceeded tool_timeout of %gs" descriptor.name seconds;
                 retryable = true;
                 metadata = [
                   ("tool_timeout_seconds", `Float seconds);
                   ("tool", `String descriptor.name);
                 ];
               }
             | Error `Cancelled ->
               Error {
                 category = Timeout;
                 message = Printf.sprintf "Tool '%s' cancelled" descriptor.name;
                 retryable = false;
                 metadata = [];
               })
          | None ->
            handler input token
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
         | None ->
           if Hashtbl.length tc_state = 1 then begin
             let buf = ref (Buffer.create 0) in
             Hashtbl.iter (fun _ (_, b) -> buf := b) tc_state;
             Buffer.add_string !buf args_json
           end)
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
  let sys = { role = System; content_blocks = Message.content_of_string system_prompt; tool_calls = None; tool_call_id = None; name = None } in
  let usr = { role = User; content_blocks = Message.content_of_string user_message; tool_calls = None; tool_call_id = None; name = None } in
  { messages = [ sys; usr ]; metadata = [] }

let add_assistant_message conv (resp : llm_response) =
  let msg = {
    role = Assistant;
    content_blocks = (match resp.text with
        | Some t -> [Text_block { text = t; cache_control = None }]
        | None -> []);
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
    content_blocks = Message.content_of_string content;
    tool_calls = None;
    tool_call_id = Some call.id;
    name = Some call.name;
  } in
  { conv with messages = conv.messages @ [ msg ] }

(* Fix 7: Structured error classification — classify LLM errors before retry decision. *)
let classify_engine_error (err : error_category) =
  let msg = match err with
    | External_failure m | Invalid_input m | Internal m -> m
    | _ -> ""
  in
  let lower = String.lowercase_ascii msg in
  let has_sub s =
    try let _ = Str.search_forward (Str.regexp_string s) lower 0 in true
    with Not_found -> false
  in
  if has_sub "context length" || has_sub "context window" 
     || has_sub "maximum context" || has_sub "too many tokens"
     || has_sub "token limit" || has_sub "context_length_exceeded" then
    `Context_length_exceeded
  else
    `Other err

(* -------------------------------------------------------------------------- *)
(* Schema-driven structured output with repair-on-failure loop.               *)
(* See docs/v0.4.8-ROADMAP.md §Feedback Retry Loop.                           *)
(* -------------------------------------------------------------------------- *)

let add_user_feedback conv feedback_message =
  let msg = {
    role = User;
    content_blocks = Message.content_of_string feedback_message;
    tool_calls = None;
    tool_call_id = None;
    name = None;
  } in
  { conv with messages = conv.messages @ [ msg ] }

(* Local pretty-printer for error_category. Cannot call
   Runtime.string_of_error_category here because Runtime depends on Engine
   (Runtime.invoke calls Engine.run_agent) — a module cycle would form.
   Mirrors Runtime.string_of_error_category verbatim. *)
let error_category_to_string (e : error_category) =
  match e with
  | Timeout -> "Timeout"
  | Invalid_input msg -> Printf.sprintf "Invalid_input: %s" msg
  | External_failure msg -> Printf.sprintf "External_failure: %s" msg
  | Rate_limited -> "Rate_limited"
  | Permission_denied msg -> Printf.sprintf "Permission_denied: %s" msg
  | Internal msg -> Printf.sprintf "Internal: %s" msg
  | Embedding_unsupported -> "Embedding_unsupported"

(* Schema-driven structured output. Calls the LLM (native structured endpoint
   when available, else a fallback that prepends a JSON-schema directive to
   the system prompt), extracts JSON from the response via Json_extract,
   validates against [response_schema], and on failure appends an assistant
   reply + user feedback message to the conversation and retries, up to
   [max_repair_attempts] times. *)
let run_structured
    ?(max_repair_attempts = 3)
    ?(on_before_llm : (conversation -> conversation option) option = None)
    ?(on_after_llm : (llm_response -> llm_response option) option = None)
    ?on_repair_attempt
    ?conversation
    ~response_schema
    (llm : llm_service)
    token (agent : agent_config) user_message =
  (* System prompt construction mirrors run_agent (engine.ml L205-216). *)
  let sys_prompt =
    let sys_prompt_sp = match Template.effective_system_prompt agent ~runtime_id:"structured" with
      | Ok sp -> sp
      | Error e ->
        let msg = match e with
          | Invalid_input m -> m
          | Internal m -> m
          | _ -> "render failed"
        in
        Logs.warn (fun m ->
          m "[engine] Template render failed (structured), falling back to plain system_prompt: %s" msg);
        agent.system_prompt
    in
    Types.prompt_text sys_prompt_sp
  in
  let conv0 = match conversation with
    | Some existing ->
      let usr = { role = User; content_blocks = Message.content_of_string user_message; tool_calls = None;
                  tool_call_id = None; name = None } in
      { existing with messages = existing.messages @ [ usr ] }
    | None -> make_conversation sys_prompt user_message
  in

  (* Dispatch: native when llm.complete_structured_fn = Some _, otherwise
     fallback that injects the schema directive into the system message text.
     The fallback does NOT add a separate User message before user_message —
     the existing user_message is preserved as the second conversation
     message, and the system message gains the schema instruction. *)
  let dispatch (model : model_config) tools conv (schema : Yojson.Safe.t) =
    match llm.complete_structured_fn with
    | Some fn -> fn model tools conv schema
    | None ->
      let directive = Printf.sprintf
        "You MUST respond with a valid JSON object matching this exact schema: %s\nDo not include any text outside the JSON object."
        (Yojson.Safe.to_string schema) in
      let messages = match conv.messages with
        | [] -> conv.messages
        | first :: rest ->
          let first_text =
            let base = Message.text_of_message first in
            base ^ "\n\n" ^ directive
          in
          { first with content_blocks = Message.content_of_string first_text } :: rest
      in
      llm.complete_fn model tools { conv with messages }
  in

  let rec loop (attempt : int) (conv : conversation)
      : (structured_invoke_result, error_category * conversation) result =
    (* BS-1: cancellation check at top of each iteration. Prevents unbounded
       LLM calls when the caller signals cancel between repair attempts. *)
    if Cancellation.is_cancelled token then
      Result.Error ((Timeout : error_category), conv)
    else begin
      (* D2: fire on_before_llm if set — conversation-aware but non-mutating
         observability hook (e.g. Logging middleware captures structured
         calls). *)
      let conv_after_before = match on_before_llm with
        | Some fn -> (match fn conv with Some c -> c | None -> conv)
        | None -> conv
      in
      let result = dispatch agent.model agent.tools conv_after_before response_schema in
      match result with
      | Error cat ->
        (* LLM/network error — propagate, no repair. HTTP retry is the
           existing Retry middleware's responsibility (it wraps on_error),
           and the structured loop only owns post-LLM parse/schema
           failures — see ROADMAP §Bypassing middleware. *)
        Result.Error (cat, conv_after_before)
      | Ok llm_resp ->
        (* D2: fire on_after_llm if set. *)
        let llm_resp_after = match on_after_llm with
          | Some fn -> (match fn llm_resp with Some r -> r | None -> llm_resp)
          | None -> llm_resp
        in
        let conv_with_assistant = add_assistant_message conv_after_before llm_resp_after in
        let text = match llm_resp_after.text with
          | Some t -> t
          | None -> ""
        in
        (match Json_extract.extract_json_from_text text with
         | Error msg ->
           (* Parse failure — feedback + retry. *)
           (match on_repair_attempt with
            | Some cb ->
              cb attempt (Invalid_input ("JSON parse: " ^ msg)) conv_with_assistant
            | None -> ());
           if attempt >= max_repair_attempts then
             Result.Error
               (Invalid_input
                  (Printf.sprintf "JSON parse failed after %d attempt(s): %s" attempt msg),
                conv_with_assistant)
           else
             let conv' = add_user_feedback conv_with_assistant
               (Printf.sprintf
                  "Your previous response was not valid JSON: %s. Please respond with valid JSON matching the schema."
                  msg) in
             loop (attempt + 1) conv'
         | Ok json ->
           (match Validation.validate_tool_input_result response_schema json with
            | Ok () ->
              Ok ({ value = json; raw_response = llm_resp_after;
                    conversation = conv_with_assistant; attempts = attempt }
                 : structured_invoke_result)
            | Error cat ->
              (match on_repair_attempt with
               | Some cb -> cb attempt cat conv_with_assistant
               | None -> ());
              if attempt >= max_repair_attempts then
                Result.Error (cat, conv_with_assistant)
              else
                let conv' = add_user_feedback conv_with_assistant
                  (Printf.sprintf
                     "Schema violation: %s. Please respond with JSON matching the schema."
                     (error_category_to_string cat)) in
                loop (attempt + 1) conv'))
    end
  in
  loop 1 conv0

(* Long-output generation mode (plan §2.1.2, §2.1.5).
   Resolve the on_max_tokens policy and continuation cap from the agent
   config, accounting for the EFFECTIVE tool set after skill overlay and
   provider-mode adjustment. [None] in the config means Auto:
   - tool-less agents get Continue with effectively unbounded chunks
     (suitable for long-output generation: PRDs, mockups, plans, docs)
   - tool-bearing agents get Return_partial with cap 3 (backwards compat) *)
let resolve_on_max_tokens ~effective_tools (agent : Types.agent_config) : Types.on_max_tokens_behavior =
  match agent.Types.on_max_tokens with
  | Some policy -> policy
  | None -> if effective_tools = [] then Types.Continue else Types.Return_partial

let resolve_max_continuation_chunks ~effective_tools (agent : Types.agent_config) : int =
  match agent.Types.max_continuation_chunks with
  | Some n -> n
  | None -> if effective_tools = [] then max_int else 3

(* v0.6.4 prompt caching: set cache_control on a content_block. *)
let set_cache_control (cc : Types.cache_control option) (block : Types.content_block) : Types.content_block =
  match block with
  | Types.Text_block tb -> Types.Text_block { tb with cache_control = cc }
  | Types.Tool_use_block tb -> Types.Tool_use_block { tb with cache_control = cc }
  | Types.Tool_result_block tb -> Types.Tool_result_block { tb with cache_control = cc }
  | Types.Image_block ib -> Types.Image_block { ib with cache_control = cc }

(* v0.6.4 prompt caching: build breakpoint candidates from current request state.
   Pri 100 = System message, pri 60 = pre-marked tool (mark_tool), pri 10 = last user block.
   Tool caching is ONLY via explicit mark_tool — no auto-guessing. *)
let build_breakpoint_candidates ~ttl ~tools ~conv : Cache_breakpoint.breakpoint list =
  let candidates = ref [] in
  let has_system = List.exists (fun (m : Types.message) -> m.role = System) conv.Types.messages in
  if has_system then
    candidates := Cache_breakpoint.{ location = `System; ttl; estimated_tokens = 1000; priority = 100 } :: !candidates;
  let last_user_idx =
    List.fold_left (fun acc (i, (m : Types.message)) ->
      if m.role = User then Some i else acc
    ) None (List.mapi (fun i m -> (i, m)) conv.Types.messages)
  in
  (match last_user_idx with
   | Some msg_idx ->
     let msg = List.nth conv.Types.messages msg_idx in
     if msg.content_blocks <> [] then begin
       let last_block_idx = List.length msg.content_blocks - 1 in
       candidates := Cache_breakpoint.{ location = `Message (msg_idx, last_block_idx); ttl; estimated_tokens = 200; priority = 10 } :: !candidates
     end
   | None -> ());
  (* Scan for pre-marked tools (user called mark_tool or set cache_control). *)
  let marked_tool_candidates =
    tools
    |> List.mapi (fun i (td : Types.tool_descriptor) ->
      match td.cache_control with
      | Some { ttl = Some tool_ttl; _ } ->
        [Cache_breakpoint.{ location = `Tool i; ttl = tool_ttl; estimated_tokens = 500; priority = 60 }]
      | _ -> [])
    |> List.concat
  in
  !candidates @ marked_tool_candidates

(* v0.6.4 prompt caching: apply cache_control markers to content_blocks
   addressed by each breakpoint. Returns a new conversation with marked blocks. *)
let apply_breakpoints ~ttl (breakpoints : Cache_breakpoint.breakpoint list) (conv : Types.conversation) :
  Types.conversation =
  if breakpoints = [] then conv
  else
    let cc = Some { Types.type_ = `Ephemeral; ttl = Some ttl } in
    let messages = List.mapi (fun i (msg : Types.message) ->
      let system_bp = List.find_opt (fun (bp : Cache_breakpoint.breakpoint) -> bp.location = `System) breakpoints in
      let msg_bps = List.filter (fun (bp : Cache_breakpoint.breakpoint) ->
        match bp.location with
        | `Message (mi, _) when mi = i -> true
        | _ -> false) breakpoints in
      let is_system_msg = (msg.role = System) in
      let blocks = List.mapi (fun j block ->
        let block = match system_bp, is_system_msg with
          | Some _bp, true when j = List.length msg.content_blocks - 1 ->
            set_cache_control cc block
          | _ -> block in
        let block =
          let targeted = List.find_opt (fun (bp : Cache_breakpoint.breakpoint) ->
            match bp.location with
            | `Message (_, bj) when bj = j -> true
            | _ -> false) msg_bps in
          match targeted with
          | Some _ -> set_cache_control cc block
          | None -> block in
        block) msg.content_blocks in
      { msg with content_blocks = blocks }
    ) conv.Types.messages in
    { conv with Types.messages = messages }

let run_agent ?(tool_mode : Types.tool_mode = `Auto)
    ?(runtime_id = "unknown") ?(steering = None) ?(followup = None)
    ?(tool_call_hooks = None) ?(quota = None) ?(parallel = false)
    ?(on_progress = None) ?(on_tool_event = None) ?(on_chunk = None)
    ?conversation ?agent_resolver ?(enable_handoff = false)
    token agent user_message llm registry =
  (* PAR-k38 T3.1: resolve effective tool mode.
     - `Auto (default): consult [llm.supports_native_tools_fn].
       [Some true] or [None] → `Native (backwards compat: every provider
       PAR ships with today sends native tools, so None assumes native).
       [Some false] → `Synthesized.
     - `Native / `Synthesized / `Json_mode: used as-is (caller's explicit choice). *)
  let effective_mode : Types.tool_mode =
    match tool_mode with
    | `Auto ->
      (match llm.Types.supports_native_tools_fn with
       | Some f when not (f ()) -> `Synthesized
       | _ -> `Native)
    | explicit -> explicit
  in
  (* When effective_mode = `Synthesized, inject tool descriptors into the
     system prompt and parse synthesised JSON tool calls out of the model's
     text response. The provider receives an EMPTY tools list so it doesn't
     double-send native tools metadata the upstream endpoint may reject. *)
  let tools_for_provider =
    if effective_mode = `Synthesized then []
    else agent.tools
  in
  (* Long-output mode (plan §2.1.5): compute resolved policy/cap ONCE from
     effective_tools so skill overlay and provider-mode adjustments are
     accounted for. The Max_tokens branch below reads these locals instead
     of the raw agent fields. *)
  let resolved_on_max_tokens = resolve_on_max_tokens ~effective_tools:tools_for_provider agent in
  let resolved_max_continuation_chunks = resolve_max_continuation_chunks ~effective_tools:tools_for_provider agent in
  let synthesized_prompt_suffix =
    if effective_mode = `Synthesized && agent.tools <> [] then
      "\n\n" ^ Tool_prompt.descriptors_to_prompt_text agent.tools
    else ""
  in
  let sys_prompt_sp = match Template.effective_system_prompt agent ~runtime_id with
    | Ok sp -> sp
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
  let sys_prompt_text = (Types.prompt_text sys_prompt_sp) ^ synthesized_prompt_suffix in
  let drain_into_conv conv queue =
    match queue with
    | None -> conv
    | Some q ->
      let msgs = Steering_queue.drain_all q in
      List.fold_left (fun c msg ->
        let usr = { role = User; content_blocks = Message.content_of_string msg; tool_calls = None;
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
      (let c = Message.text_of_message msg in
       if c = "" then "<none>" else c))
  in
  let start_time = Unix.gettimeofday () in
  let last_compress_iter = ref (-1_000_000) in
  let reactive_attempts = ref 0 in
  let rec loop ~agent ~global_max conv iterations =
    let global_max = max global_max agent.max_iterations in
    let elapsed = Unix.gettimeofday () -. start_time in
    let max_time = Option.value agent.max_execution_time ~default:infinity in
    if elapsed > max_time then
      Result.Error ((Timeout : error_category), conv)
    else if iterations >= global_max then (
      match (agent.early_stopping_method : Types.early_stopping_method) with
      | Types.Force -> Result.Error ((Internal "Max iterations exceeded" : error_category), conv)
      | Types.Generate ->
        let conv' = add_user_feedback conv
          "Based on the work done so far, provide your best final answer." in
        (* v0.6.4: apply cache marks before final Generate call *)
        let conv' =
          match agent.cache_strategy with
          | Types.No_caching -> conv'
          | Types.With_cache_of ttl ->
            let candidates = build_breakpoint_candidates ~ttl ~tools:tools_for_provider ~conv:conv' in
            let plan = Cache_breakpoint.plan_breakpoints llm candidates in
            let fire_evt evt = match on_tool_event with Some pub -> pub evt | None -> () in
            List.iter (fun (bp, reason) ->
              fire_evt (Types.Cache_breakpoint_dropped {
                location = bp.Cache_breakpoint.location;
                reason;
              })
            ) plan.dropped;
            apply_breakpoints ~ttl plan.used conv'
        in
        (match run_llm_with_optional_streaming llm agent.model tools_for_provider conv' on_chunk with
         | Ok resp ->
           let conv'' = add_assistant_message conv' resp in
           Ok (resp, conv'')
         | Error _ -> Result.Error ((Internal "Max iterations exceeded" : error_category), conv))
    )
    else begin
      Cancellation.check_cancel token;
      (* PAR-p70: ratio-based auto-compression gate.
         - threshold=None means manual mode: apply strategy unconditionally (current behavior).
         - threshold=Some r means auto mode: apply strategy only when ratio crosses r AND cooldown elapsed.
         - When strategy=None and threshold fires, fall back to default Summarize. *)
      let conv =
        let tokens_before = Context_manager.estimate_tokens conv in
        let messages_before = List.length conv.messages in
        let should_fire, skip_reason =
          Context_manager.should_compress
            ~threshold:agent.context_compression_threshold
            ~cooldown:agent.compression_cooldown_messages
            ~llm ~model:agent.model ~conv
            ~iterations_since_last_compress:(iterations - !last_compress_iter)
            ~window_override:agent.context_window_override
        in
        let fire_evt evt = match on_tool_event with Some pub -> pub evt | None -> () in
        (match skip_reason with
         | Some r -> fire_evt (Context_compression_skipped { reason = r })
         | None -> ());
        match agent.context_strategy, agent.context_compression_threshold, should_fire with
        | None, None, _ -> conv
        | None, Some _, false -> conv
        | None, Some _, true ->
          let resolved_window =
            Context_manager.resolve_context_window
              ~llm ~model:agent.model ~user_override:agent.context_window_override
          in
          let budget = max 8000 (resolved_window / 8) in
          let compress_start = Unix.gettimeofday () in
          (match Context_manager.apply_default_summarize
             ~llm ~model:agent.model ~window:resolved_window ~on_event:on_tool_event conv with
           | Ok conv' ->
             let elapsed_ms =
               int_of_float ((Unix.gettimeofday () -. compress_start) *. 1000.0)
             in
             fire_evt (Context_compressed {
               trigger = Option.value agent.context_compression_threshold ~default:0.8;
               tokens_before;
               tokens_after = Context_manager.estimate_tokens conv';
               messages_before;
               messages_after = List.length conv'.messages;
               strategy_used = Summarize { max_tokens = budget; summary_model = Some agent.model };
               elapsed_ms;
             });
             last_compress_iter := iterations;
             conv'
           | Error _ -> conv)
        | Some strategy, None, _ ->
          (* manual mode: apply unconditionally (preserves pre-p70 behavior) *)
          (match Context_manager.apply_strategy strategy conv (Some llm) ~on_event:on_tool_event with
           | Ok conv' -> conv'
           | Error _ -> conv)
        | Some _strategy, Some _, false -> conv
        | Some strategy, Some _, true ->
          let compress_start = Unix.gettimeofday () in
          (match Context_manager.apply_strategy strategy conv (Some llm) ~on_event:on_tool_event with
           | Ok conv' ->
             let elapsed_ms =
               int_of_float ((Unix.gettimeofday () -. compress_start) *. 1000.0)
             in
             fire_evt (Context_compressed {
               trigger = Option.value agent.context_compression_threshold ~default:0.8;
               tokens_before;
               tokens_after = Context_manager.estimate_tokens conv';
               messages_before;
               messages_after = List.length conv'.messages;
               strategy_used = strategy;
               elapsed_ms;
             });
             last_compress_iter := iterations;
             conv'
           | Error _ -> conv)
      in
      let conv = apply_before_llm agent.middleware conv (fun c -> c) in
      (* v0.6.4 prompt caching: plan breakpoints and apply cache_control markers *)
      let conv =
        match agent.cache_strategy with
        | Types.No_caching -> conv
        | Types.With_cache_of ttl ->
          let candidates = build_breakpoint_candidates
            ~ttl ~tools:tools_for_provider ~conv in
          let plan = Cache_breakpoint.plan_breakpoints llm candidates in
          let fire_evt evt = match on_tool_event with Some pub -> pub evt | None -> () in
          List.iter (fun (bp, reason) ->
            fire_evt (Types.Cache_breakpoint_dropped {
              location = bp.Cache_breakpoint.location;
              reason;
            })
          ) plan.dropped;
          apply_breakpoints ~ttl plan.used conv
      in
      Logs.info (fun m -> m "[engine] LLM call iter=%d: %d messages, agent=%s model=%s"
        iterations (List.length conv.messages) agent.id agent.model.model_name);
      List.iteri log_message conv.messages;
      let llm_task_id = Task_id.create () in
      let fire_llm evt = match on_tool_event with
        | Some pub -> pub evt
        | None -> ()
      in
      fire_llm (Llm_request_sent { task_id = llm_task_id; model = agent.model.model_name });
      match run_llm_with_optional_streaming llm agent.model tools_for_provider conv on_chunk with
      | Result.Error err ->
        (match classify_engine_error err with
         | `Context_length_exceeded ->
            incr reactive_attempts;
            if !reactive_attempts > 2 then
              Result.Error ((Internal "Context length exceeded after compression attempts" : error_category), conv)
            else begin
              Logs.warn (fun m -> m "[engine] Context length exceeded (reactive attempt %d/2), applying context strategy" !reactive_attempts);
              let conv = match agent.context_strategy with
                | Some strategy ->
                  (match Context_manager.apply_strategy strategy conv (Some llm) ~on_event:on_tool_event with
                   | Ok conv' -> conv'
                   | Error _ -> conv)
                | None when agent.context_compression_threshold <> None ->
                  let resolved_w =
                    Context_manager.resolve_context_window
                      ~llm ~model:agent.model ~user_override:agent.context_window_override
                  in
                  (match Context_manager.apply_default_summarize
                     ~llm ~model:agent.model ~window:resolved_w ~on_event:on_tool_event conv with
                   | Ok conv' -> conv'
                   | Error _ -> conv)
                | None ->
                  Context_manager.truncate_conversation ~keep_system:true ~min_messages:2
                    ~max_tokens:8000 conv
              in
              last_compress_iter := iterations;
              loop ~agent ~global_max conv (iterations + 1)
            end
          | `Other err_classified ->
           let err_classified : error_category = err_classified in
           let action = apply_on_error agent.middleware conv err_classified
             (fun e -> Error { category = e; message = "LLM error"; retryable = false; metadata = [] })
           in
           (match action with
            | Error { retryable = true; _ } -> loop ~agent ~global_max conv (iterations + 1)
            | Handoff _ -> Result.Error ((Internal "Handoff reached retry path" : error_category), conv)
            | _ -> Result.Error (err_classified, conv)))
        | Ok resp ->
        reactive_attempts := 0;
        fire_llm (Llm_response_received { task_id = llm_task_id; usage = resp.usage });
        let resp = apply_after_llm agent.middleware resp (fun r -> r) in
        (* PAR-k38 T3.1: in Synthesized mode, extract tool calls from the
           model's text response when the provider didn't return native ones. *)
        let resp =
          if effective_mode = `Synthesized then
            match resp.tool_calls with
            | Some calls when calls <> [] -> resp
            | _ ->
              let text = match resp.text with Some t -> t | None -> "" in
              let parsed = Tool_prompt.parse_tool_calls_from_text text in
              if parsed <> [] then
                { resp with tool_calls = Some parsed;
                            finish_reason = (match resp.finish_reason with
                                             | Stop -> Tool_calls | fr -> fr) }
              else resp
          else resp
        in
        Logs.info (fun m -> m "[engine] LLM response iter=%d: finish=%s text_len=%d tool_calls=%s"
          iterations
          (match resp.finish_reason with Stop -> "stop" | Tool_calls -> "tool_calls"
           | Max_tokens -> "max_tokens" | Content_filter -> "content_filter")
          (match resp.text with Some t -> String.length t | None -> 0)
          (match resp.tool_calls with Some tcs -> string_of_int (List.length tcs) | None -> "none"));
        match resp.tool_calls with
        | Some calls when calls <> [] && agent.tools <> [] ->
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
                  | Some handler -> (call, execute_tool token descriptor handler original_input agent.middleware on_progress ~tool_call_id:call.id ~tool_timeout:agent.tool_timeout))
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
                let sp = match Template.effective_system_prompt target_agent ~runtime_id with
                  | Ok sp -> sp
                  | Error _ -> target_agent.system_prompt
                in
                Types.prompt_text sp
              in
              (match carry_context with
               | true ->
                 let non_sys = List.filter
                   (fun (m : message) -> m.role <> System) conv.messages in
                 let sys_msg = {
                   role = System; content_blocks = Message.content_of_string target_sys_prompt;
                   tool_calls = None; tool_call_id = None; name = None
                 } in
                 let new_conv = { conv with messages = sys_msg :: non_sys } in
                 loop ~agent:target_agent ~global_max new_conv (iterations + 1)
               | false ->
                 (match task with
                  | Some t ->
                    let sys_msg = {
                      role = System; content_blocks = Message.content_of_string target_sys_prompt;
                      tool_calls = None; tool_call_id = None; name = None
                    } in
                    let user_msg = {
                      role = User; content_blocks = Message.content_of_string t;
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
            let has_content = match resp.text with
              | Some t when String.length (String.trim t) > 0 -> true
              | _ -> false
            in
            fire_llm (Llm_response_truncated {
              task_id = llm_task_id; model = agent.model.model_name;
              finish_reason = Max_tokens });
            (match (resolved_on_max_tokens : Types.on_max_tokens_behavior) with
             | Types.Return_partial ->
               if has_content then begin
                 let conv = add_assistant_message conv resp in
                 let conv = drain_into_conv conv followup in
                 Ok (resp, conv)
               end else
                 if iterations + 1 >= global_max then Result.Error (Internal "Max iterations exceeded", conv)
                 else loop ~agent ~global_max conv (iterations + 1)
             | Types.Retry ->
               let conv = add_assistant_message conv resp in
               let conv = drain_into_conv conv followup in
               if iterations + 1 >= global_max then Result.Error (Internal "Max iterations exceeded with truncated output", conv)
               else loop ~agent ~global_max conv (iterations + 1)
             | Types.Continue when not has_content ->
               if iterations + 1 >= global_max then Result.Error (Internal "Max iterations exceeded", conv)
               else loop ~agent ~global_max conv (iterations + 1)
             | Types.Continue ->
               let conv = add_assistant_message conv resp in
               let initial_text = Option.value resp.text ~default:"" in
               (* R1 mitigation (plan §2.5): wall-clock sub-cap on the Continue
                  sub-loop, set to 50% of max_execution_time. Guards against
                  runaway models that always emit >500 chars per chunk and
                  would otherwise slip past the diminishing-returns guard. *)
               let continue_start = Unix.gettimeofday () in
               let sub_cap = (Option.value agent.max_execution_time ~default:infinity) *. 0.5 in
               let rec continue_chunks ~start ~cap conv accumulated chunks =
                 if chunks >= resolved_max_continuation_chunks then
                   ({ resp with text = Some accumulated; finish_reason = Max_tokens }, conv)
                 else if Unix.gettimeofday () -. start > cap then
                   ({ resp with text = Some accumulated; finish_reason = Max_tokens }, conv)
                 else
                   let conv = add_user_feedback conv
                     "Continue from where your previous response stopped. Do not repeat previous content." in
                   (match run_llm_with_optional_streaming llm agent.model tools_for_provider conv on_chunk with
                    | Error _ ->
                      ({ resp with text = Some accumulated; finish_reason = Max_tokens }, conv)
                    | Ok cont_resp ->
                      let new_text = Option.value cont_resp.text ~default:"" in
                      let conv = add_assistant_message conv cont_resp in
                      let combined = accumulated ^ new_text in
                      (match cont_resp.finish_reason with
                       | Stop | Content_filter ->
                         ({ cont_resp with text = Some combined; finish_reason = Stop }, conv)
                       | _ ->
                         if String.length (String.trim new_text) < 500 then
                           ({ cont_resp with text = Some combined; finish_reason = Max_tokens }, conv)
                         else
                           continue_chunks ~start ~cap conv combined (chunks + 1)))
               in
               let (final_resp, final_conv) = continue_chunks ~start:continue_start ~cap:sub_cap conv initial_text 1 in
               let final_conv = drain_into_conv final_conv followup in
               Ok (final_resp, final_conv)
            )
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
      let usr = { role = User; content_blocks = Message.content_of_string user_message; tool_calls = None;
                  tool_call_id = None; name = None } in
      { existing with messages = existing.messages @ [ usr ] }
    | None ->
      Logs.info (fun m -> m "[engine] New conversation: system_prompt=%d chars, user_message=%d chars"
        (String.length sys_prompt_text) (String.length user_message));
      make_conversation sys_prompt_text user_message
  in
  loop ~agent ~global_max:0 conv 0
