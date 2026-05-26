open Types

type transition_error =
  | Self_transition of task_status
  | Terminal_source of task_status
  | Invalid of task_status * task_status

let transition_error_to_string = function
  | Self_transition s ->
    Printf.sprintf "Self-transition not allowed: %s" (status_to_string s)
  | Terminal_source s ->
    Printf.sprintf "Terminal state cannot transition: %s" (status_to_string s)
  | Invalid (from, to_) ->
    Printf.sprintf "Invalid transition: %s -> %s"
      (status_to_string from) (status_to_string to_)

let validate from to_ =
  let is_terminal = function Completed | Failed | Cancelled -> true | _ -> false in
  if from = to_ then Result.Error (Self_transition from)
  else if is_terminal from then Result.Error (Terminal_source from)
  else if List.mem (from, to_) valid_transitions then Ok ()
  else Result.Error (Invalid (from, to_))

let transition persist_fn (task : task_state) new_status =
  match validate task.status new_status with
  | Result.Error e -> Result.Error (transition_error_to_string e)
  | Ok () ->
    let updated = { task with status = new_status; updated_at = Unix.time () } in
    persist_fn updated;
    Ok updated

let apply_backoff policy attempt =
  match policy.backoff with
  | Exponential { base; max_delay } ->
    Float.min (base *. Float.pow 2.0 (Float.of_int attempt)) max_delay
  | Fixed delay -> delay
  | Linear { increment; max_delay } ->
    Float.min (increment *. Float.of_int (attempt + 1)) max_delay

let apply_jitter delay = function
  | Some factor ->
    let random_factor = 1.0 -. Random.float (2.0 *. factor) in
    delay *. random_factor
  | None -> delay

let _should_retry policy (error_cat : error_category) =
  List.exists (fun (cond : retryable_condition) ->
    match cond with
    | Any_retryable -> true
    | Timeout -> error_cat = Timeout
    | Rate_limited -> error_cat = Rate_limited
    | External_failure ->
      (match error_cat with Types.External_failure _ -> true | _ -> false)
    | Connection_error -> false
  ) policy.retry_on

let apply_retry task policy =
  if task.retry_count >= policy.max_attempts then
    Result.Error `Max_retries_exceeded
  else
    let backoff = apply_backoff policy task.retry_count in
    let delay = apply_jitter backoff policy.jitter in
    let updated = { task with
      retry_count = task.retry_count + 1;
      status = Scheduled;
      updated_at = Unix.time ();
      schedule = Some (`Delay delay);
    } in
    Ok updated
