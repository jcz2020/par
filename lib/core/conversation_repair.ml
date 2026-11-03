open Types

(* Provider replay requires two invariants that the rest of the engine cannot
   take for granted once a conversation has been truncated, loaded from disk, or
   handed in by a caller:

   1. Every tool result refers to a tool_call in the immediately preceding
      assistant turn.
   2. Every tool_call in that assistant turn has a matching tool result.

   PAR carries tool calls in two shapes: the OpenAI-style [tool_calls] field and
   Anthropic-style [Tool_use_block] / [Tool_result_block] content blocks.  Both
   are first-class in the public type and both must be handled here.  A
   drop-oldest truncation can cut between (1) and (2), leaving an orphan result
   at the front.  A malformed model response can leave [arguments] as a
   non-object, which providers reject as an invalid function call.  This module
   is the single place that normalizes and repairs those shapes. *)

let is_object = function `Assoc _ -> true | _ -> false

let warn_non_object ~id ~name arguments =
  Logs.warn (fun m -> m
    "conversation_repair: tool_call %s (%s) had non-object arguments %s; \
     replacing with {}"
    id name (Yojson.Safe.to_string arguments))

let normalize_tool_call (tc : tool_call) =
  if is_object tc.arguments then tc
  else begin
    warn_non_object ~id:tc.id ~name:tc.name tc.arguments;
    { tc with arguments = `Assoc [] }
  end

let normalize_content_block = function
  | Tool_use_block ({ id; name; arguments; _ } as block) when not (is_object arguments) ->
    warn_non_object ~id ~name arguments;
    Tool_use_block { block with arguments = `Assoc [] }
  | block -> block

let normalize_arguments (conv : conversation) : conversation =
  { conv with
    messages = List.map (fun (msg : message) ->
      let tool_calls = Option.map (List.map normalize_tool_call) msg.tool_calls in
      let field_ids = match tool_calls with
        | Some calls -> List.map (fun (tc : tool_call) -> tc.id) calls
        | None -> []
      in
      let content_blocks =
        List.map normalize_content_block msg.content_blocks
        |> List.filter (function
          | Tool_use_block { id; _ } -> not (List.mem id field_ids)
          | _ -> true)
      in
      { msg with tool_calls; content_blocks }) conv.messages }

type pending_call = { id : string; name : string }

(* Calls can be carried by the [tool_calls] field, by [Tool_use_block] content,
   or (in malformed/legacy data) both.  Deduplicate by id, field first. *)
let calls_of_message (msg : message) : tool_call list =
  let from_field = Option.value msg.tool_calls ~default:[] in
  let from_blocks =
    match msg.role with
    | Assistant ->
      List.filter_map (function
        | Tool_use_block { id; name; arguments; _ } ->
          Some { id; name; arguments }
        | _ -> None
      ) msg.content_blocks
    | _ -> []
  in
  let seen = Hashtbl.create 8 in
  List.filter (fun (tc : tool_call) ->
    if Hashtbl.mem seen tc.id then false
    else begin Hashtbl.add seen tc.id (); true end
  ) (from_field @ from_blocks)

(* Results can be carried by a Tool-role message's [tool_call_id] or by
   [Tool_result_block] content in any message.  Deduplicate by tool_use_id. *)
let results_of_message (msg : message) : (string * string option) list =
  let from_field =
    match msg.role, msg.tool_call_id with
    | Tool, Some id -> [id, msg.name]
    | _ -> []
  in
  let from_blocks =
    match msg.role with
    | User | Tool ->
      List.filter_map (function
        | Tool_result_block { tool_use_id; _ } -> Some (tool_use_id, None)
        | _ -> None
      ) msg.content_blocks
    | _ -> []
  in
  let seen = Hashtbl.create 8 in
  List.filter (fun (id, _) ->
    if Hashtbl.mem seen id then false
    else begin Hashtbl.add seen id (); true end
  ) (from_field @ from_blocks)

let strip_orphan_result_blocks (msg : message) orphan_ids : message =
  if orphan_ids = [] then msg
  else
    { msg with content_blocks =
        List.filter (function
          | Tool_result_block { tool_use_id; _ } ->
            not (List.mem tool_use_id orphan_ids)
          | _ -> true
        ) msg.content_blocks }

(* Tool_use belongs in an Assistant message; Tool_result belongs in a User or
   Tool message.  A block in the wrong role cannot be replayed by either
   provider, so repair removes it. *)
let strip_role_invalid_blocks (msg : message) : message =
  let content_blocks =
    List.filter (function
      | Tool_use_block _ -> msg.role = Assistant
      | Tool_result_block _ -> msg.role = User || msg.role = Tool
      | _ -> true
    ) msg.content_blocks
  in
  if List.length content_blocks = List.length msg.content_blocks then msg
  else begin
    Logs.warn (fun m -> m
      "conversation_repair: dropping tool blocks in invalid role %s"
      (match msg.role with
       | System -> "System" | User -> "User" | Assistant -> "Assistant" | Tool -> "Tool"));
    { msg with content_blocks }
  end

let synthetic_result (call : pending_call) : message =
  { role = Tool;
    content_blocks = Message.content_of_string
      (Printf.sprintf
         "[context repair] Tool result for tool_call %s (%s) was missing after \
          conversation compaction; the tool was not re-run."
         call.id call.name);
    tool_calls = None;
    tool_call_id = Some call.id;
    name = None;
  }

(** Drop orphan results and synthesize a result for any call that lost its
    result.  The result satisfies {!validate} by construction. *)
let repair_tool_pairs (conv : conversation) : conversation =
  let conv = normalize_arguments conv in
  let pending : (string, pending_call) Hashtbl.t = Hashtbl.create 8 in
  let pending_order = ref [] in
  let out_rev = ref [] in
  let append msg = out_rev := msg :: !out_rev in
  let remember calls =
    List.iter (fun (tc : tool_call) ->
      if not (Hashtbl.mem pending tc.id) then begin
        Hashtbl.add pending tc.id { id = tc.id; name = tc.name };
        pending_order := tc.id :: !pending_order
      end
    ) calls
  in
  let remove_pending id =
    Hashtbl.remove pending id;
    pending_order := List.filter (fun x -> x <> id) !pending_order
  in
  let flush_pending () =
    List.iter (fun id ->
      match Hashtbl.find_opt pending id with
      | Some call ->
        Logs.warn (fun m -> m
          "conversation_repair: synthesizing missing Tool result for \
           tool_call %s (%s)" call.id call.name);
        append (synthetic_result call)
      | None -> ()
    ) (List.rev !pending_order);
    Hashtbl.clear pending;
    pending_order := []
  in
  List.iter (fun (msg : message) ->
    let msg = strip_role_invalid_blocks msg in
    let results = results_of_message msg in
    let valid_results, orphan_results =
      List.partition (fun (id, _) -> Hashtbl.mem pending id) results
    in
    let valid_ids = List.map fst valid_results in
    let orphan_ids = List.map fst orphan_results in
    let msg' = strip_orphan_result_blocks msg orphan_ids in
    let calls = calls_of_message msg in
    let drop_if_empty msg =
      if msg.content_blocks = [] && msg.tool_calls = None then ()
      else append msg
    in
    match msg.role with
    | Tool ->
      let keep =
        match msg.tool_call_id with
        | Some id -> List.mem id valid_ids
        | None -> valid_results <> []
      in
      if keep then begin
        List.iter remove_pending valid_ids;
        append msg'
      end else begin
        (* Do not consume valid_results here: this message is being dropped,
           so any call it claimed to answer must stay pending and get a
           synthetic result later. *)
        match msg.tool_call_id with
        | Some id ->
          Logs.warn (fun m -> m
            "conversation_repair: dropping orphan Tool result %s (no matching \
             tool_call in the kept window)" id)
        | None ->
          Logs.warn (fun m -> m
            "conversation_repair: dropping Tool message without tool_call_id")
      end
    | Assistant when calls <> [] ->
      List.iter remove_pending valid_ids;
      (* Results must follow the assistant turn that issued the calls.  If a
         new assistant turn starts first, the previous batch is dangling. *)
      flush_pending ();
      append msg';
      remember calls
    | _ ->
      List.iter remove_pending valid_ids;
      if valid_results <> [] then append msg'
      else if calls <> [] then begin
        flush_pending ();
        append msg';
        remember calls
      end else begin
        flush_pending ();
        drop_if_empty msg'
      end
  ) conv.messages;
  flush_pending ();
  { conv with messages = List.rev !out_rev }

(** Strict pre-request check.

    Every result must have a matching tool_call in the preceding assistant
    turn, every tool_call must have a result before the next non-result
    message, and no arguments may be non-objects.  Handoff calls are ordinary
    tool calls: the engine appends their `<handoff>` result before switching
    agents, so a dangling handoff is a real error rather than an exception. *)
let validate (conv : conversation) : (unit, string) result =
  let pending : (string, pending_call) Hashtbl.t = Hashtbl.create 8 in
  let pending_order = ref [] in
  let error = ref None in
  let fail msg = if !error = None then error := Some msg in
  let remove_pending id =
    Hashtbl.remove pending id;
    pending_order := List.filter (fun x -> x <> id) !pending_order
  in
  let render_pending () =
    List.filter_map (Hashtbl.find_opt pending) !pending_order
    |> List.map (fun c -> Printf.sprintf "%s (name=%s)" c.id c.name)
    |> String.concat ", "
  in
  let fail_pending where =
    if Hashtbl.length pending > 0 then
      fail (Printf.sprintf "tool_call %s has no matching Tool result%s"
              (render_pending ()) where)
  in
  let forget_pending () =
    Hashtbl.clear pending;
    pending_order := []
  in
  List.iteri (fun i (msg : message) ->
    List.iter (function
      | Tool_use_block { id; _ } when msg.role <> Assistant ->
        fail (Printf.sprintf
          "Tool_use_block %s appears in a %s message at index %d" id
          (match msg.role with
           | System -> "System" | User -> "User" | Assistant -> "Assistant" | Tool -> "Tool") i)
      | Tool_result_block { tool_use_id; _ }
        when msg.role <> User && msg.role <> Tool ->
        fail (Printf.sprintf
          "Tool_result_block %s appears in a %s message at index %d" tool_use_id
          (match msg.role with
           | System -> "System" | User -> "User" | Assistant -> "Assistant" | Tool -> "Tool") i)
      | _ -> ()) msg.content_blocks;
    let results = results_of_message msg in
    List.iter (fun (id, _) ->
      if Hashtbl.mem pending id then remove_pending id
      else begin
        let name_suffix = match msg.name with
          | Some n -> Printf.sprintf " (name=%s)" n
          | None -> ""
        in
        fail (Printf.sprintf
          "Tool result %s%s at index %d has no matching tool_call"
          id name_suffix i)
      end
    ) results;
    let calls = calls_of_message msg in
    List.iter (fun (tc : tool_call) ->
      if not (is_object tc.arguments) then
        fail (Printf.sprintf
          "tool_call %s (name=%s) has non-object arguments %s"
          tc.id tc.name (Yojson.Safe.to_string tc.arguments))
    ) calls;
    if calls <> [] then begin
      fail_pending (Printf.sprintf " before message at index %d" i);
      forget_pending ();
      List.iter (fun (tc : tool_call) ->
        if not (Hashtbl.mem pending tc.id) then begin
          Hashtbl.add pending tc.id { id = tc.id; name = tc.name };
          pending_order := tc.id :: !pending_order
        end
      ) calls
    end else if results = [] then begin
      if msg.role = Tool then
        fail (Printf.sprintf
          "Tool message at index %d has no tool_call_id or Tool_result_block" i);
      fail_pending (Printf.sprintf " before message at index %d" i)
    end
  ) conv.messages;
  fail_pending " at the end of the conversation";
  match !error with
  | Some msg -> Error msg
  | None -> Ok ()
