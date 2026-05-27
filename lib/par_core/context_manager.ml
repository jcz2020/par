open Types

let chars_per_token = 4
let default_max_tokens = 4000

let estimate_tokens conv =
  let char_count = List.fold_left (fun acc (msg : message) ->
    let content_len = match msg.content with
      | Some s -> String.length s
      | None -> 0
    in
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
    let content = match m.content with Some s -> s | None -> "" in
    Printf.sprintf "[%s]: %s" (role_str m.role) content
  ) msgs |> String.concat "\n"

let apply_truncate_oldest ~keep_system ~min_messages conv =
  truncate_conversation ~keep_system ~min_messages ~max_tokens:default_max_tokens conv

let apply_summarize max_tokens summary_model conv llm_opt =
  let tokens = estimate_tokens conv in
  if tokens <= max_tokens then Ok conv
  else
    let total = List.length conv.messages in
    let keep_recent = min 4 total in
    let recent_count = if keep_recent >= total then total else keep_recent in
    let to_summarize, to_keep =
      let n = total - recent_count in
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
            { role = System; content = Some "You are a helpful assistant that summarizes conversations concisely.";
              tool_calls = None; tool_call_id = None; name = None };
            { role = User; content = Some prompt_text;
              tool_calls = None; tool_call_id = None; name = None };
          ];
          metadata = [];
        } in
        (match llm.complete_fn model summary_conv with
         | Ok resp ->
           (match resp.text with
            | Some summary_text ->
              let summary_msg : message = {
                role = System;
                content = Some (Printf.sprintf "[Conversation Summary]\n%s" summary_text);
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

let apply_strategy strategy conv llm_opt =
  match strategy with
  | Truncate_oldest { keep_system; min_messages } ->
    Ok (apply_truncate_oldest ~keep_system ~min_messages conv)
  | Summarize { max_tokens; summary_model } ->
    apply_summarize max_tokens summary_model conv llm_opt
  | Sliding_window { max_messages; max_tokens } ->
    Ok (apply_sliding_window max_messages max_tokens conv)
