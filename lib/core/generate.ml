open Types

(* -------------------------------------------------------------------------- *)
(* Internal helpers (mirrors engine.ml patterns, copied to keep this module  *)
(* decoupled from Engine per plan §3.1.3). Do NOT call out to Engine.       *)
(* -------------------------------------------------------------------------- *)

let make_conversation system_prompt user_message =
  let sys = { role = System; content_blocks = Message.content_of_string system_prompt;
              tool_calls = None; tool_call_id = None; name = None } in
  let usr = { role = User; content_blocks = Message.content_of_string user_message;
              tool_calls = None; tool_call_id = None; name = None } in
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

let add_user_feedback conv feedback_message =
  let msg = {
    role = User;
    content_blocks = Message.content_of_string feedback_message;
    tool_calls = None;
    tool_call_id = None;
    name = None;
  } in
  { conv with messages = conv.messages @ [ msg ] }

let run_llm_with_optional_streaming llm agent_model conv user_cb =
  match user_cb with
  | None -> llm.complete_fn agent_model [] conv
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
    let stream_cfg : stream_config =
      { chunk_timeout = 30.0; total_timeout = None; buffer_size = 4096 } in
    match llm.stream_fn agent_model [] conv stream_cfg acc with
    | Error _ as e -> e
    | Ok stream_complete ->
      let entries = Hashtbl.fold (fun id (name, buf) acc ->
        (id, name, Buffer.contents buf) :: acc) tc_state [] in
      let tool_calls = if entries = [] then None else
        Some (List.map (fun (id, name, args_str) ->
          let arguments =
            try Yojson.Safe.from_string args_str with _ -> `Null in
          { id; name; arguments }) entries) in
      let text =
        if Buffer.length text_buf = 0 then None else Some (Buffer.contents text_buf) in
      Ok { text; tool_calls; finish_reason = stream_complete.finish_reason;
           usage = stream_complete.final_usage; model = agent_model.model_name }

(* -------------------------------------------------------------------------- *)
(* run — long-output pure generation                                       *)
(* -------------------------------------------------------------------------- *)

let run ?session_id ~agent ~message ?max_output_tokens ?total_timeout
    ?on_tool_event ?on_chunk ~cancellation_token ~llm () =
  let start_time = Unix.gettimeofday () in
  let session_id = Option.value session_id ~default:"unknown" in
  let conv0 = make_conversation agent.system_prompt message in

  let fire evt = match on_tool_event with
    | Some pub -> pub evt
    | None -> ()
  in

  let model_for_call =
    match max_output_tokens with
    | None -> agent.model
    | Some n -> { agent.model with max_tokens = Some n }
  in

  (* Mutable counters threaded through the loop without using a record type. *)
  let total_tokens = ref 0 in
  let any_usage_seen = ref false in
  let continuations = ref 0 in

  let finalize_ok finish text conv =
    let elapsed = Unix.gettimeofday () -. start_time in
    let total_tokens_opt : int option =
      if !any_usage_seen then Some !total_tokens else None in
    Ok ({
      text;
      finish_reason = finish;
      continuations = !continuations;
      total_tokens = total_tokens_opt;
      session_id;
      elapsed;
    }, conv)
  in

  let rec loop conv accumulated =
    Cancellation.check_cancel cancellation_token;
    (match total_timeout with
     | Some t when Unix.gettimeofday () -. start_time > t ->
       if accumulated <> "" then
         finalize_ok Max_tokens accumulated conv
       else
         let elapsed = Unix.gettimeofday () -. start_time in
         Logs.warn (fun m -> m
           "[generate] total_timeout=%.1fs exceeded with no accumulated text (elapsed=%.2fs)"
           t elapsed);
         Error ((Timeout : error_category), conv)
     | _ ->
       let task_id = Task_id.create () in
       fire (Llm_request_sent { task_id; model = model_for_call.model_name });
       (match run_llm_with_optional_streaming llm model_for_call conv on_chunk with
        | Error err ->
          Logs.warn (fun m -> m
            "[generate] LLM call failed: %s"
            (match err with
             | Timeout -> "Timeout"
             | Invalid_input m | Internal m | External_failure m -> m
             | _ -> "<other>"));
          Error (err, conv)
        | Ok resp ->
          fire (Llm_response_received { task_id; usage = resp.usage });
          total_tokens := !total_tokens + resp.usage.total_tokens;
          any_usage_seen := true;
          let new_text = Option.value resp.text ~default:"" in
          (* Edge case (spec §Step 3): empty initial response — model returned
             no content AND hit Max_tokens. Continuing would not help; surface
             it as a hard error so callers can retry with a larger budget. *)
          let is_initial = accumulated = "" in
          let empty_initial =
            is_initial && resp.text = None && resp.finish_reason = Max_tokens in
          let conv = add_assistant_message conv resp in
          (match resp.finish_reason with
           | Stop | Content_filter ->
             Logs.info (fun m -> m
               "[generate] final answer: finish=%s, %d chars, %d continuations"
               (match resp.finish_reason with
                | Stop -> "Stop" | Content_filter -> "Content_filter"
                | _ -> "Other") (String.length new_text) !continuations);
             (* Use accumulated text (concatenated across continuations),
                matching Engine.run_agent's Continue branch behavior
                (engine.ml: `{ cont_resp with text = Some combined }`).
                Without this, long-output callers would receive only the
                last chunk instead of the full artifact. *)
             finalize_ok Stop (accumulated ^ new_text) conv
           | Max_tokens when empty_initial ->
             Logs.warn (fun m -> m
               "[generate] initial response returned no content with Max_tokens; \
                treating as hard error");
             Error ((Internal "Generate failed: model returned no content" : error_category), conv)
           | Max_tokens ->
             fire (Llm_response_truncated
                     { task_id; model = model_for_call.model_name;
                       finish_reason = Max_tokens });
             let combined = accumulated ^ new_text in
             if accumulated <> ""
                && String.length (String.trim new_text) < 500 then begin
               Logs.info (fun m -> m
                 "[generate] diminishing-returns: new chunk=%d chars (trimmed), terminating partial"
                 (String.length (String.trim new_text)));
               finalize_ok Max_tokens combined conv
             end else begin
               let conv = add_user_feedback conv
                 "Continue from where your previous response stopped. Do not repeat previous content." in
               fire (Generate_continuation
                       { task_id; chunk_index = !continuations;
                         chars_added = String.length new_text });
               incr continuations;
               Logs.info (fun m -> m
                 "[generate] continue chunk=%d: previous=%d chars, new_chunk=%d chars"
                 !continuations (String.length accumulated) (String.length new_text));
               loop conv combined
             end
           | Tool_calls ->
             Logs.warn (fun m -> m
               "[generate] unexpected tool_calls in pure-generation mode; \
                treating as Stop and ignoring %d tool call(s)"
               (List.length (Option.value resp.tool_calls ~default:[])));
             finalize_ok Stop (accumulated ^ new_text) conv)))
  in

  Logs.info (fun m -> m
    "[generate] starting pure generation: session=%s model=%s \
     system_prompt=%d chars user_message=%d chars total_timeout=%s"
    session_id agent.model.model_name
    (String.length agent.system_prompt) (String.length message)
    (match total_timeout with Some t -> Printf.sprintf "%.1fs" t | None -> "none"));
  loop conv0 ""
