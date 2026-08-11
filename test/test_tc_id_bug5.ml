(* Test that streaming tool_call reconstruction preserves insertion order.
   Verifies that a list-based order tracking produces deterministic output. *)


let test_ordered_reconstruction () =
  (* Simulate the ordered accumulator pattern *)
  let tc_state : (string, (string * Buffer.t)) Hashtbl.t = Hashtbl.create 4 in
  let tc_order : string list ref = ref [] in
  let start id name =
    if not (Hashtbl.mem tc_state id) then
      tc_order := id :: !tc_order;
    Hashtbl.replace tc_state id (name, Buffer.create 64)
  in
  let delta id args =
    match Hashtbl.find_opt tc_state id with
    | Some (_, buf) -> Buffer.add_string buf args
    | None -> ()
  in
  start "call_A" "search";
  start "call_B" "fetch";
  start "call_C" "compute";
  delta "call_A" "{\"q\":1}";
  delta "call_B" "{\"url\":2}";
  delta "call_C" "{\"x\":3}";
  let entries = List.rev_map (fun id ->
    let (name, buf) = Hashtbl.find tc_state id in
    (id, name, Buffer.contents buf)) !tc_order in
  let ids = List.map (fun (id, _, _) -> id) entries in
  Alcotest.(check string) "first is call_A" "call_A" (List.nth ids 0);
  Alcotest.(check string) "second is call_B" "call_B" (List.nth ids 1);
  Alcotest.(check string) "third is call_C" "call_C" (List.nth ids 2)

let () =
  Alcotest.run "tool_call_id BUG 5 (PAR-9jq)" [
    "ordered_reconstruction", [
      Alcotest.test_case "insertion order preserved" `Quick test_ordered_reconstruction;
    ];
  ]
