type counters = {
  llm_requests_total : int Atomic.t;
  task_completed_total : int Atomic.t;
  task_failed_total : int Atomic.t;
  tool_invocations_total : int Atomic.t;
  events_published_total : int Atomic.t;
  events_dropped_total : int Atomic.t;
}

let empty () = {
  llm_requests_total = Atomic.make 0;
  task_completed_total = Atomic.make 0;
  task_failed_total = Atomic.make 0;
  tool_invocations_total = Atomic.make 0;
  events_published_total = Atomic.make 0;
  events_dropped_total = Atomic.make 0;
}

let incr_llm c = Atomic.incr c.llm_requests_total
let incr_task_completed c = Atomic.incr c.task_completed_total
let incr_task_failed c = Atomic.incr c.task_failed_total
let incr_tool_invocations c = Atomic.incr c.tool_invocations_total
let incr_events_published c = Atomic.incr c.events_published_total
let incr_events_dropped c = Atomic.incr c.events_dropped_total

let snapshot c = [
  ("llm_requests_total", Atomic.get c.llm_requests_total);
  ("task_completed_total", Atomic.get c.task_completed_total);
  ("task_failed_total", Atomic.get c.task_failed_total);
  ("tool_invocations_total", Atomic.get c.tool_invocations_total);
  ("events_published_total", Atomic.get c.events_published_total);
  ("events_dropped_total", Atomic.get c.events_dropped_total);
]

let merge_into ~target ~source =
  let add f = Atomic.set (f target) (Atomic.get (f target) + Atomic.get (f source)) in
  add (fun c -> c.llm_requests_total);
  add (fun c -> c.task_completed_total);
  add (fun c -> c.task_failed_total);
  add (fun c -> c.tool_invocations_total);
  add (fun c -> c.events_published_total);
  add (fun c -> c.events_dropped_total)
