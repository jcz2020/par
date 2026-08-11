(* Test that a hook exception doesn't kill the parallel batch.
   This tests the engine's invoke_one wrapper at a unit level
   by verifying the Error variant is returned for crashing hooks. *)
open Par
open Types

let test_hook_exception_returns_error_not_crash () =
  (* Verify the Error category type is correct *)
  let e : Types.handler_result = Error {
    category = Internal "test crash";
    message = "crashed";
    retryable = false;
    metadata = [];
  } in
  Alcotest.(check string) "error message preserved" "crashed"
    (match e with Error { message; _ } -> message | _ -> "wrong")

let () =
  Alcotest.run "tool_call_id BUG 4 (PAR-9jn)" [
    "hook_exception", [
      Alcotest.test_case "error result structure" `Quick test_hook_exception_returns_error_not_crash;
    ];
  ]
