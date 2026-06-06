open Par
open Types

let test_extract_task_id_task_events () =
  let tid = Task_id.create () in
  Alcotest.(check string) "Task_created"
    (Task_id.to_string tid)
    (Persistence_common.extract_task_id
       (Task_created { task_id = tid; task_type = ""; priority = 0 }));
  Alcotest.(check string) "Task_started"
    (Task_id.to_string tid)
    (Persistence_common.extract_task_id (Task_started { task_id = tid }));
  Alcotest.(check string) "Task_completed"
    (Task_id.to_string tid)
    (Persistence_common.extract_task_id
       (Task_completed { task_id = tid; duration_ms = 1.0 }));
  Alcotest.(check string) "Task_failed"
    (Task_id.to_string tid)
    (Persistence_common.extract_task_id
       (Task_failed { task_id = tid; error = Internal "x" }))

let test_extract_task_id_tool_events () =
  let tid = Task_id.create () in
  Alcotest.(check string) "Tool_invoked"
    (Task_id.to_string tid)
    (Persistence_common.extract_task_id
       (Tool_invoked { task_id = tid; tool_name = "echo" }));
  Alcotest.(check string) "Tool_completed"
    (Task_id.to_string tid)
    (Persistence_common.extract_task_id
       (Tool_completed { task_id = tid; tool_name = "echo"; duration_ms = 1.0 }))

let test_extract_task_id_workflow_events () =
  let rid = Workflow_run_id.create () in
  Alcotest.(check string) "Workflow_started"
    (Workflow_run_id.to_string rid)
    (Persistence_common.extract_task_id
       (Workflow_started { workflow_run_id = rid }));
  Alcotest.(check string) "Workflow_completed"
    (Workflow_run_id.to_string rid)
    (Persistence_common.extract_task_id
       (Workflow_completed { workflow_run_id = rid }))

let test_extract_task_id_non_task_events_return_empty () =
  Alcotest.(check string) "Approval_requested" ""
    (Persistence_common.extract_task_id
       (Approval_requested { prompt = ""; allowed_roles = [] }));
  Alcotest.(check string) "Shutdown_initiated" ""
    (Persistence_common.extract_task_id Shutdown_initiated);
  Alcotest.(check string) "Mcp_server_started" ""
    (Persistence_common.extract_task_id
       (Mcp_server_started { server_id = "srv-1"; server_name = "x" }))

let () =
  Alcotest.run "persistence_common" [
    ("extract_task_id", [
      Alcotest.test_case "task-lifecycle events" `Quick test_extract_task_id_task_events;
      Alcotest.test_case "tool events" `Quick test_extract_task_id_tool_events;
      Alcotest.test_case "workflow events" `Quick test_extract_task_id_workflow_events;
      Alcotest.test_case "non-task events return empty" `Quick
        test_extract_task_id_non_task_events_return_empty;
    ]);
  ]
