open Types

(* Provider replay requires two invariants that the rest of the engine cannot
   take for granted once a conversation has been truncated, loaded from disk, or
   handed in by a caller:

   1. Every Tool message's [tool_call_id] refers to a tool_call in the
      immediately preceding assistant turn.
   2. Every tool_call in that assistant turn has a matching Tool message.

   A drop-oldest truncation can cut between (1) and (2), leaving an orphan Tool
   message at the front.  A malformed model response can leave [arguments] as a
   non-object, which providers reject as an invalid function call.  This module
   is the single place that normalizes and repairs those shapes. *)

let is_object = function `Assoc _ -> true | _ -> false

let normalize_tool_call (tc : tool_call) =
  if is_object tc.arguments then tc
  else begin
    Logs.warn (fun m -> m
      "conversation_repair: tool_call %s (%s) had non-object arguments %s; \
       replacing with {}"
      tc.id tc.name (Yojson.Safe.to_string tc.arguments));
    { tc with arguments = `Assoc [] }
  end

let normalize_arguments (conv : conversation) : conversation =
  let changed = ref false in
  let messages =
    List.map (fun (msg : message) ->
      match msg.role, msg.tool_calls with
      | Assistant, Some calls ->
        let calls' = List.map normalize_tool_call calls in
        if calls' != calls then changed := true;
        { msg with tool_calls = Some calls' }
      | _ -> msg
    ) conv.messages
  in
  if !changed then { conv with messages } else conv

type pending_call = { id : string; name : string }

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

(** Drop orphan Tool messages and synthesize a result for any tool_call that
    lost its result.  The result is provider-replay valid by construction. *)
let repair_tool_pairs (conv : conversation) : conversation =
  let pending : (string, pending_call) Hashtbl.t = Hashtbl.create 8 in
  let pending_order = ref [] in
  let out_rev = ref [] in
  let append msg = out_rev := msg :: !out_rev in
  let remember call =
    if not (Hashtbl.mem pending call.id) then begin
      Hashtbl.add pending call.id call;
      pending_order := call.id :: !pending_order
    end
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
    match msg.role with
    | Assistant ->
      (* Results must follow the assistant turn that issued the calls.  If a
         new assistant turn starts first, the previous batch is dangling. *)
      flush_pending ();
      append msg;
      (match msg.tool_calls with
       | Some calls -> List.iter (fun (tc : tool_call) ->
           remember { id = tc.id; name = tc.name }) calls
       | None -> ())
    | Tool ->
      (match msg.tool_call_id with
       | Some id when Hashtbl.mem pending id ->
         Hashtbl.remove pending id;
         pending_order := List.filter (fun x -> x <> id) !pending_order;
         append msg
       | Some id ->
         Logs.warn (fun m -> m
           "conversation_repair: dropping orphan Tool result %s (no matching \
            tool_call in the kept window)" id)
       | None ->
         Logs.warn (fun m -> m
           "conversation_repair: dropping Tool message without tool_call_id"))
    | _ ->
      flush_pending ();
      append msg
  ) conv.messages;
  flush_pending ();
  { conv with messages = List.rev !out_rev }

(** Strict pre-request check for the provider-fatal direction.

    Every Tool result must have a matching tool_call in the preceding assistant
    turn, and no tool_call arguments may be a non-object.  A tool_call without
    a Tool result is intentionally accepted: handoff calls are control flow and
    never produce a result, and PAR's handoff path carries that assistant turn
    into the target agent unchanged.  Truncation safety is handled by
    {!repair_tool_pairs}, which does synthesize missing results. *)
let validate (conv : conversation) : (unit, string) result =
  let pending : (string, pending_call) Hashtbl.t = Hashtbl.create 8 in
  let pending_order = ref [] in
  let error = ref None in
  let fail msg = if !error = None then error := Some msg in
  let forget_pending () =
    Hashtbl.clear pending;
    pending_order := []
  in
  List.iteri (fun i (msg : message) ->
    match msg.role with
    | Assistant ->
      forget_pending ();
      (match msg.tool_calls with
       | Some calls ->
         List.iter (fun (tc : tool_call) ->
           if not (is_object tc.arguments) then
             fail (Printf.sprintf
               "tool_call %s (name=%s) has non-object arguments %s"
               tc.id tc.name (Yojson.Safe.to_string tc.arguments));
           if not (Hashtbl.mem pending tc.id) then begin
             Hashtbl.add pending tc.id { id = tc.id; name = tc.name };
             pending_order := tc.id :: !pending_order
           end
         ) calls
       | None -> ())
    | Tool ->
      (match msg.tool_call_id with
       | None ->
         fail (Printf.sprintf
           "Tool message at index %d has no tool_call_id" i)
       | Some id ->
         if Hashtbl.mem pending id then begin
           Hashtbl.remove pending id;
           pending_order := List.filter (fun x -> x <> id) !pending_order
         end else begin
           let name_suffix = match msg.name with
             | Some n -> Printf.sprintf " (name=%s)" n
             | None -> ""
           in
           fail (Printf.sprintf
             "Tool result %s%s at index %d has no matching tool_call"
             id name_suffix i)
         end)
    | _ -> forget_pending ()
  ) conv.messages;
  match !error with
  | Some msg -> Error msg
  | None -> Ok ()
