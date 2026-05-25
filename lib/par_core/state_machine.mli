open Types

type transition_error =
  | Self_transition of task_status
  | Terminal_source of task_status
  | Invalid of task_status * task_status

val transition_error_to_string : transition_error -> string

val validate : task_status -> task_status -> (unit, transition_error) result

val transition :
  (task_state -> unit) ->
  task_state ->
  task_status ->
  (task_state, string) result

val apply_retry :
  task_state ->
  retry_policy ->
  (task_state, [> `Max_retries_exceeded ]) result
