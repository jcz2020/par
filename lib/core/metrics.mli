type counters

val empty : unit -> counters

val incr_llm : counters -> unit
val incr_task_completed : counters -> unit
val incr_task_failed : counters -> unit
val incr_tool_invocations : counters -> unit
val incr_events_published : counters -> unit
val incr_events_dropped : counters -> unit

val snapshot : counters -> (string * int) list

(** [merge_into ~target ~source] atomically adds every counter in [source]
    into the corresponding counter in [target]. Used at [Runtime.invoke] exit
    to fold a per-call accumulator into the runtime-wide counters. Both
    operands use [Atomic] fields so the merge is race-free even when multiple
    invokes exit concurrently. *)
val merge_into : target:counters -> source:counters -> unit
