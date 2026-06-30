open Types

let chars_per_token = 4
let default_max_tokens = 4000

let estimate_tokens conv =
  let char_count = List.fold_left (fun acc (msg : message) ->
    let content_len = String.length (Message.string_of_content msg.content_blocks) in
    let tc_len = match msg.tool_calls with
      | Some tcs ->
        List.fold_left (fun acc (tc : tool_call) ->
          acc + String.length tc.id + String.length tc.name
            + String.length (Yojson.Safe.to_string tc.arguments)
        ) 0 tcs
      | None -> 0
    in
    let name_len = match msg.name with
      | Some s -> String.length s
      | None -> 0
    in
    let tcid_len = match msg.tool_call_id with
      | Some s -> String.length s
      | None -> 0
    in
    acc + content_len + tc_len + name_len + tcid_len
  ) 0 conv.messages in
  char_count / chars_per_token

let truncate_conversation ?(keep_system = true) ~min_messages ~max_tokens conv =
  let system_msgs, other_msgs =
    List.partition (fun (m : message) -> m.role = System) conv.messages
  in
  let kept_system = if keep_system then system_msgs else [] in
  let remaining_from = List.length other_msgs in
  if remaining_from <= min_messages then
    { conv with messages = kept_system @ other_msgs }
  else begin
    let tokens = estimate_tokens conv in
    if tokens <= max_tokens then conv
    else begin
      let rec drop_oldest msgs =
        let len = List.length msgs in
        if len <= min_messages then msgs
        else begin
          let candidate = if keep_system then kept_system @ List.tl msgs else List.tl msgs in
          let est = estimate_tokens { conv with messages = candidate } in
          if est <= max_tokens || len - 1 <= min_messages then List.tl msgs
          else drop_oldest (List.tl msgs)
        end
      in
      let trimmed = drop_oldest other_msgs in
      { conv with messages = kept_system @ trimmed }
    end
  end

let format_messages_for_summary msgs =
  let role_str = function
    | System -> "System"
    | User -> "User"
    | Assistant -> "Assistant"
    | Tool -> "Tool"
  in
  List.map (fun (m : message) ->
    let content = Message.text_of_message m in
    Printf.sprintf "[%s]: %s" (role_str m.role) content
  ) msgs |> String.concat "\n"

let apply_truncate_oldest ~keep_system ~min_messages conv =
  truncate_conversation ~keep_system ~min_messages ~max_tokens:default_max_tokens conv

let apply_summarize max_tokens summary_model conv llm_opt ~on_event =
  let tokens = estimate_tokens conv in
  if tokens <= max_tokens then Ok conv
  else
    let total = List.length conv.messages in
    let keep_recent = min 4 total in
    let recent_count = if keep_recent >= total then total else keep_recent in
    let to_summarize, to_keep =
      let initial_n = total - recent_count in
      let rec balance_boundary n =
        if n <= 0 then 0
        else
          match List.nth_opt conv.messages n with
          | Some { role = Tool; _ } -> balance_boundary (n - 1)
          | _ -> n
      in
      let n = balance_boundary initial_n in
      (List.filteri (fun i _ -> i < n) conv.messages,
       List.filteri (fun i _ -> i >= n) conv.messages)
    in
    if to_summarize = [] then Ok conv
    else
      match llm_opt, summary_model with
      | Some llm, Some model ->
        let prompt_text =
          Printf.sprintf
            "Summarize the following conversation, preserving key facts, decisions, and context needed for continuation:\n\n%s"
            (format_messages_for_summary to_summarize)
        in
        let summary_conv : conversation = {
          messages = [
            { role = System; content_blocks = [Text_block { text = "You are a helpful assistant that summarizes conversations concisely."; cache_control = None }];
              tool_calls = None; tool_call_id = None; name = None };
            { role = User; content_blocks = [Text_block { text = prompt_text; cache_control = None }];
              tool_calls = None; tool_call_id = None; name = None };
          ];
          metadata = [];
        } in
        let summary_task_id = Task_id.create () in
        let fire evt = match on_event with
          | Some fn -> fn evt
          | None -> ()
        in
        fire (Llm_request_sent { task_id = summary_task_id; model = model.model_name });
        (match llm.complete_fn model [] summary_conv with
         | Ok resp ->
           fire (Llm_response_received { task_id = summary_task_id; usage = resp.usage });
           (match resp.text with
            | Some summary_text ->
              let summary_msg : message = {
                role = System;
                content_blocks = Message.content_of_string (Printf.sprintf "[Conversation Summary]\n%s" summary_text);
                tool_calls = None; tool_call_id = None; name = None;
              } in
              Ok { conv with messages = summary_msg :: to_keep }
            | None ->
              Ok (apply_truncate_oldest ~keep_system:true ~min_messages:4 conv))
         | Error _ ->
           Ok (apply_truncate_oldest ~keep_system:true ~min_messages:4 conv))
      | _ ->
        Ok (apply_truncate_oldest ~keep_system:true ~min_messages:4 conv)

let apply_sliding_window max_messages max_tokens conv =
  let system_msgs, other_msgs =
    List.partition (fun (m : message) -> m.role = System) conv.messages
  in
  let other_count = List.length other_msgs in
  let truncated_other =
    if other_count <= max_messages then other_msgs
    else
      let drop = other_count - max_messages in
      let rec skip n lst = match lst with [] -> [] | _ :: rest when n > 0 -> skip (n - 1) rest | _ -> lst in
      skip drop other_msgs
  in
  let conv' = { conv with messages = system_msgs @ truncated_other } in
  let tokens = estimate_tokens conv' in
  if tokens <= max_tokens then conv'
  else
    let min_keep = max 2 (List.length system_msgs) in
    truncate_conversation ~keep_system:true ~min_messages:min_keep ~max_tokens conv'

let apply_strategy strategy conv llm_opt ~on_event =
  match strategy with
  | Truncate_oldest { keep_system; min_messages } ->
    Ok (apply_truncate_oldest ~keep_system ~min_messages conv)
  | Summarize { max_tokens; summary_model } ->
    apply_summarize max_tokens summary_model conv llm_opt ~on_event
  | Sliding_window { max_messages; max_tokens } ->
    Ok (apply_sliding_window max_messages max_tokens conv)

(* PAR-p70: pure helpers for auto context compression *)

let default_context_window (model : model_config) =
  let name = String.lowercase_ascii model.model_name in
  let has_sub needle =
    if needle = "" then false
    else
      try
        let _ = Str.search_forward (Str.regexp_string needle) name 0 in true
      with Not_found -> false
  in
  (* Ordering invariant: most specific substrings first so e.g. "gpt-4o"
     matches before bare "gpt-4". Reordering this chain WILL break the
     gpt-4o/turbo precedence. *)
  if has_sub "gpt-4o" then 128000
  else if has_sub "gpt-4-turbo" then 128000
  else if has_sub "gpt-3.5-turbo" then 16385
  else if has_sub "gpt-4" then 8192
  else if has_sub "claude-sonnet-4" then 200000
  else if has_sub "claude-opus-4" then 200000
  else if has_sub "claude-haiku-3.5" then 200000
  else if has_sub "claude-3-5-sonnet" then 200000
  else if has_sub "claude-3-5-haiku" then 200000
  else if has_sub "claude-3-opus" then 200000
  else if has_sub "claude-3-haiku" then 100000
  else if has_sub "o4-mini" then 200000
  else if has_sub "o1" then 200000
  else if has_sub "o3" then 200000
  else 8000

let resolve_context_window ~llm ~model ~user_override =
  match user_override with
  | Some n -> n
  | None ->
    match llm.context_window_fn with
    | Some fn ->
      let n = fn () in
      if n > 0 then n else default_context_window model
    | None -> default_context_window model

let estimated_tokens_with_margin conv =
  let raw = estimate_tokens conv in
  int_of_float (float_of_int raw *. 1.2)

let should_compress ~threshold ~cooldown ~llm ~model ~conv
    ~iterations_since_last_compress ~window_override =
  match threshold with
  | None -> (false, None)
  | Some threshold_r ->
    let window = resolve_context_window ~llm ~model ~user_override:window_override in
    if window <= 0 then (false, Some `No_window_size)
    else
      let tokens = estimated_tokens_with_margin conv in
      let ratio = float_of_int tokens /. float_of_int window in
      if ratio < threshold_r then
        (false, Some (`Below_threshold ratio))
      else
        match cooldown with
        | Some cd when iterations_since_last_compress < cd ->
          (false, Some (`Cooldown_active (cd - iterations_since_last_compress)))
        | _ -> (true, None)

let apply_default_summarize ~llm ~model ~window ~on_event conv =
  let budget = max 8000 (window / 8) in
  apply_summarize budget (Some model) conv (Some llm) ~on_event
