(* HITL approval types — outcome ADT + parameterized handler.
   approval_context lives in Types (it references Types.conversation),
   which keeps this module free of any Types dependency and breaks
   the otherwise-cyclic .cmi graph.  The ['ctx] parameter on
   approval_handler is instantiated by the engine to Types.approval_context.
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
(* Approval handler (parameterized — no concrete context type here)          *)
(* -------------------------------------------------------------------------- *)

type 'ctx approval_handler =
  | Sync_local of ('ctx -> approval_outcome)
  | Async_callback of ('ctx -> approval_outcome Eio.Promise.t)
  | Webhook of { url : string; secret : string; timeout_sec : float }

(* -------------------------------------------------------------------------- *)
(* Constants                                                                 *)
(* -------------------------------------------------------------------------- *)

let default_timeout = 300.0
