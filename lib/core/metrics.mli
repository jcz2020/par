type counters

val empty : unit -> counters

val incr_llm : counters -> unit
val incr_task_completed : counters -> unit
val incr_task_failed : counters -> unit
val incr_tool_invocations : counters -> unit
val incr_events_published : counters -> unit
val incr_events_dropped : counters -> unit

val snapshot : counters -> (string * int) list
