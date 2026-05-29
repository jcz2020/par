(* Paper §6 metric collectors — pure functions, no IO, no Eio *)

open Par.Types

(* §6(a): Compile-time vs Runtime error detection ratio *)
let type_safety_ratio (errors : (string * bool) list) =
  let total = List.length errors in
  if total = 0 then 1.0
  else
    let type_caught = List.filter snd errors |> List.length in
    float_of_int type_caught /. float_of_int total

(* §6(b): Tool execution correctness — name-based positional comparison *)
let tool_call_accuracy ~expected ~actual =
  let expected_names = List.map (fun (tc : tool_call) -> tc.name) expected in
  let actual_names = List.map (fun (tc : tool_call) -> tc.name) actual in
  let total = List.length expected in
  if total = 0 then 1.0
  else
    let min_len = min (List.length expected_names) (List.length actual_names) in
    let rec count acc i =
      if i >= min_len then acc
      else
        let e = List.nth expected_names i in
        let a = List.nth actual_names i in
        count (if e = a then acc + 1 else acc) (i + 1)
    in
    float_of_int (count 0 0) /. float_of_int total

(* Check if tool sequence is in correct ORDER *)
let tool_sequence_order ~expected ~actual =
  let expected_names = List.map (fun (tc : tool_call) -> tc.name) expected in
  let actual_names = List.map (fun (tc : tool_call) -> tc.name) actual in
  if expected_names = actual_names then 1.0 else 0.0

(* §6(c): State machine transition soundness — mirrors Types.valid_transitions *)
let valid_transition = function
  | (Pending, Scheduled)
  | (Pending, Cancelled)
  | (Scheduled, Running)
  | (Scheduled, Cancelled)
  | (Running, Waiting_input)
  | (Running, Suspended)
  | (Running, Completed)
  | (Running, Failed)
  | (Running, Cancelled)
  | (Waiting_input, Running)
  | (Waiting_input, Completed)
  | (Waiting_input, Failed)
  | (Waiting_input, Cancelled)
  | (Suspended, Scheduled)
  | (Suspended, Running)
  | (Suspended, Completed)
  | (Suspended, Failed)
  | (Suspended, Cancelled) ->
    true
  | _ -> false

let transition_soundness (transitions : (task_status * task_status) list) =
  if List.length transitions = 0 then 1.0
  else
    let valid = List.filter valid_transition transitions |> List.length in
    float_of_int valid /. float_of_int (List.length transitions)

let all_statuses =
  [ Pending; Scheduled; Running; Waiting_input; Suspended; Completed; Failed; Cancelled ]

let reachable_states () =
  let rec bfs visited queue =
    match queue with
    | [] -> visited
    | status :: rest ->
      if List.mem status visited then bfs visited rest
      else
        let next =
          List.filter_map
            (fun s -> if valid_transition (status, s) then Some s else None)
            all_statuses
        in
        bfs (status :: visited) (rest @ next)
  in
  bfs [] [Pending]

let state_reachability_ratio () =
  let reachable = reachable_states () in
  float_of_int (List.length reachable) /. float_of_int (List.length all_statuses)

(* §6(d): Middleware composition correctness *)

let test_identity_law (f : 'a -> 'a) (x : 'a) =
  let id_fn = Fun.id in
  f (id_fn x) = id_fn (f x)

let test_associativity (f : 'a -> 'a) (g : 'a -> 'a) (h : 'a -> 'a) (x : 'a) =
  let f_g_h x = f (g (h x)) in
  let f_g x = f (g x) in
  f_g_h x = f_g (h x)

let middleware_composition_score (hooks : middleware_hook list) =
  if List.length hooks < 2 then 1.0
  else
    let active =
      List.filter
        (fun (h : middleware_hook) ->
          h.on_before_llm <> None
          || h.on_after_llm <> None
          || h.on_before_tool <> None
          || h.on_after_tool <> None
          || h.on_error <> None)
        hooks
    in
    float_of_int (List.length active) /. float_of_int (List.length hooks)
