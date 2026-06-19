open Types

let extract_task_id : event -> string = function
  | Task_created { task_id; _ } -> Task_id.to_string task_id
  | Task_started { task_id } -> Task_id.to_string task_id
  | Task_completed { task_id; _ } -> Task_id.to_string task_id
  | Task_failed { task_id; _ } -> Task_id.to_string task_id
  | Task_cancelled { task_id; _ } -> Task_id.to_string task_id
  | Task_suspended { task_id } -> Task_id.to_string task_id
  | Task_resumed { task_id } -> Task_id.to_string task_id
  | Llm_request_sent { task_id; _ } -> Task_id.to_string task_id
  | Llm_response_received { task_id; _ } -> Task_id.to_string task_id
  | Tool_invoked { task_id; _ } -> Task_id.to_string task_id
  | Tool_completed { task_id; _ } -> Task_id.to_string task_id
  | Tool_failed { task_id; _ } -> Task_id.to_string task_id
  | Tool_progress { task_id; _ } -> Task_id.to_string task_id
  | Bash_invoked { task_id; _ } -> Task_id.to_string task_id
  | Bash_completed { task_id; _ } -> Task_id.to_string task_id
  | Workflow_started { workflow_run_id } -> Workflow_run_id.to_string workflow_run_id
  | Workflow_step_completed { step_id } -> step_id
  | Workflow_completed { workflow_run_id } -> Workflow_run_id.to_string workflow_run_id
  | Workflow_failed { workflow_run_id; _ } -> Workflow_run_id.to_string workflow_run_id
  | Approval_requested _ -> ""
  | Approval_granted _ -> ""
  | Approval_timeout -> ""
  | Shutdown_initiated -> ""
  | Shutdown_completed _ -> ""
  | Mcp_server_started _ -> ""
  | Mcp_server_failed _ -> ""
  | Mcp_server_stopped _ -> ""
  | Mcp_tool_invoked _ -> ""
  | Mcp_tool_completed _ -> ""
  | Mcp_resource_read _ -> ""
  | Mcp_prompt_rendered _ -> ""
  | Agent_handoff { task_id; _ } -> Task_id.to_string task_id
  | Structured_output_completed { task_id; _ } -> Task_id.to_string task_id

let extract_session_id (envelope : event_envelope) : string =
  envelope.metadata.session_id