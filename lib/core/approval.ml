(* HITL approval types — outcome ADT, context record, handler variants.
   Companion to the [Approval_required] variant in [Types.handler_result].
   Phantom type ('sync, 'async) handler deferred to v0.8.1 per ROADMAP §4. *)

(* -------------------------------------------------------------------------- *)
(* Approval outcome                                                          *)
(* -------------------------------------------------------------------------- *)

type approval_outcome =
  | Approved
  | Rejected of { reason : string }
  | Modified of { new_input : Yojson.Safe.t }
  | Escalated of { target : string }
  | Timeout

let outcome_to_json = function
  | Approved -> `String "Approved"
  | Rejected { reason } ->
    `Assoc [ ("tag", `String "Rejected"); ("reason", `String reason) ]
  | Modified { new_input } ->
    `Assoc [ ("tag", `String "Modified"); ("new_input", new_input) ]
  | Escalated { target } ->
    `Assoc [ ("tag", `String "Escalated"); ("target", `String target) ]
  | Timeout -> `String "Timeout"

let outcome_of_json json =
  let open Yojson.Safe.Util in
  try
    match json with
    | `String "Approved" -> Ok Approved
    | `String "Timeout" -> Ok Timeout
    | `Assoc _ as obj ->
      (match member "tag" obj with
       | `String "Rejected" ->
         let reason = member "reason" obj |> to_string in
         Ok (Rejected { reason })
       | `String "Modified" ->
         let new_input = member "new_input" obj in
         Ok (Modified { new_input })
       | `String "Escalated" ->
         let target = member "target" obj |> to_string in
         Ok (Escalated { target })
       | _ -> Error "approval_outcome_of_json: unknown tag")
    | _ -> Error "approval_outcome_of_json: invalid shape"
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Error (Printf.sprintf "approval_outcome_of_json: %s" msg)

(* -------------------------------------------------------------------------- *)
(* Approval context                                                          *)
(* -------------------------------------------------------------------------- *)

type approval_context = {
  agent_id : string;
  tool_name : string;
  tool_input : Yojson.Safe.t;
  conversation : Types.conversation;
  pending_action : Yojson.Safe.t;
  metadata : (string * Yojson.Safe.t) list;
}

(* -------------------------------------------------------------------------- *)
(* Approval handler                                                          *)
(* -------------------------------------------------------------------------- *)

type approval_handler =
  | Sync_local of (approval_context -> approval_outcome)
  | Async_callback of (approval_context -> approval_outcome Eio.Promise.t)
  | Webhook of { url : string; secret : string; timeout_sec : float }

(* -------------------------------------------------------------------------- *)
(* Constants                                                                 *)
(* -------------------------------------------------------------------------- *)

let default_timeout = 300.0
