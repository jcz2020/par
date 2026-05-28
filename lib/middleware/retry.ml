open Types

(* Default retry policy: exponential backoff, 3 attempts, retry on
   timeout / rate-limit / external failures. *)

let default_policy : retry_policy = {
  max_attempts = 3;
  initial_delay = 1.0;
  backoff = Exponential { base = 2.0; max_delay = 30.0 };
  retry_on = [ Timeout; Rate_limited; External_failure ];
  jitter = None;
}

(* Compute delay for a given attempt number using the backoff strategy.
   Applies optional jitter: delay * (1 + jitter * random_in[-1,1]) *)

let compute_delay (policy : retry_policy) (attempt : int) : float =
  let raw =
    match policy.backoff with
    | Exponential { base; max_delay } ->
      Float.min (base ** float_of_int attempt) max_delay
    | Fixed delay ->
      delay
    | Linear { increment; max_delay } ->
      Float.min (increment *. float_of_int attempt) max_delay
  in
  match policy.jitter with
  | None -> raw
  | Some j -> raw *. (1.0 +. j *. (Random.float 2.0 -. 1.0))

(* Check whether an error_category matches any condition in the retry_on list.
   Both types share constructor names (Timeout, Rate_limited, External_failure)
   so we match explicitly by type context. *)

let is_retryable (retry_on : retryable_condition list) (err : error_category) : bool =
  List.exists (fun (cond : retryable_condition) ->
    match cond with
    | Timeout ->
      (match err with Timeout -> true | _ -> false)
    | Rate_limited ->
      (match err with Rate_limited -> true | _ -> false)
    | External_failure ->
      (match err with External_failure _ -> true | _ -> false)
    | Connection_error ->
      false
    | Any_retryable ->
      (match err with
       | Timeout | Rate_limited | External_failure _ -> true
       | _ -> false)
  ) retry_on

let retry ?(policy = default_policy) () : middleware_hook =
  let attempt = ref 0 in
  {
    name = "retry";
    on_before_llm = None;
    on_after_llm = None;
    on_before_tool = None;
    on_after_tool = None;
    on_error = Some (fun (err : error_category) ->
      if !attempt < policy.max_attempts && is_retryable policy.retry_on err then begin
        incr attempt;
        let delay = compute_delay policy !attempt in
        Some (Error {
          category = err;
          message = Printf.sprintf "Retrying (attempt %d/%d)..." !attempt policy.max_attempts;
          retryable = true;
          metadata = [
            ("attempt", `Int !attempt);
            ("delay", `Float delay);
          ];
        })
      end else begin
        (* Exhausted retries or non-retryable — pass through *)
        attempt := 0;
        None
      end
    );
  }
