(* Runtime metrics counters — 63-bit OCaml int, no overflow risk *)

type counters = {
  mutable llm_requests_total : int;
  mutable task_completed_total : int;
  mutable task_failed_total : int;
  mutable tool_invocations_total : int;
  mutable events_published_total : int;
  mutable events_dropped_total : int;
}

let empty () = {
  llm_requests_total = 0;
  task_completed_total = 0;
  task_failed_total = 0;
  tool_invocations_total = 0;
  events_published_total = 0;
  events_dropped_total = 0;
}

let incr_llm c = c.llm_requests_total <- c.llm_requests_total + 1
let incr_task_completed c = c.task_completed_total <- c.task_completed_total + 1
let incr_task_failed c = c.task_failed_total <- c.task_failed_total + 1
let incr_tool_invocations c = c.tool_invocations_total <- c.tool_invocations_total + 1
let incr_events_published c = c.events_published_total <- c.events_published_total + 1
let incr_events_dropped c = c.events_dropped_total <- c.events_dropped_total + 1

let snapshot c = [
  ("llm_requests_total", c.llm_requests_total);
  ("task_completed_total", c.task_completed_total);
  ("task_failed_total", c.task_failed_total);
  ("tool_invocations_total", c.tool_invocations_total);
  ("events_published_total", c.events_published_total);
  ("events_dropped_total", c.events_dropped_total);
]
