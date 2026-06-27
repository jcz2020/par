open Types

(** Simplified configuration for the retry middleware.  When provided, the
    values override the corresponding fields in [default_policy]. *)

type retry_config = {
  max_attempts : int;
  base_delay : float;
  max_delay : float;
}

let default_retry_config : retry_config = {
  max_attempts = 3;
  base_delay = 2.0;
  max_delay = 30.0;
}

(* Default retry policy: exponential backoff, 3 attempts, retry on
   timeout / rate-limit / external failures. *)

let _default_policy : retry_policy = {
  max_attempts = 3;
  initial_delay = 1.0;
  backoff = Exponential { base = 2.0; max_delay = 30.0 };
  retry_on = [ Timeout; Rate_limited; External_failure ];
  jitter = None;
}

let policy_of_config (cfg : retry_config) : retry_policy = {
  max_attempts = cfg.max_attempts;
  initial_delay = cfg.base_delay;
  backoff = Exponential { base = cfg.base_delay; max_delay = cfg.max_delay };
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

(* PAR-6ad (GH#16): per-conversation retry counter.

   The previous implementation stored [attempt] as a [ref int] captured
   in the middleware closure. That ref was shared across every
   conversation that used this middleware instance — including two
   concurrent [Runtime.invoke] calls on the same agent — so one
   invocation's LLM errors would silently consume the other
   invocation's retry budget.

   The fix is to key the attempt counter on the conversation
   ([conversation -> error_category -> ...]). Each [Runtime.invoke]
   call constructs its own conversation, so distinct concurrent
   invocations always have distinct conversation values and therefore
   isolated retry counters. The middleware instance is still a single
   shared value (created by [Retry.retry]) — only the counter table
   is keyed by conversation hash.

   The hashtbl is mutated only from inside [on_error], which the
   engine dispatches synchronously on the fiber that originated the
   LLM call. Two concurrent invocations always have different
   conversation hashes, so they never mutate the same entry
   concurrently. The hashtbl therefore does not need a mutex. *)

let retry ?(config = default_retry_config) ?(policy : retry_policy option) () : middleware_hook =
  let effective_policy = match policy with
    | Some p -> p
    | None -> policy_of_config config
  in
  (* Per-instance attempt table keyed by conversation hash.
     Each retry() call gets its own table, so different middleware
     instances don't interfere. Within one instance, different
     conversations (different invoke calls) get isolated counters. *)
  let attempts : (int, int) Hashtbl.t = Hashtbl.create 16 in
  {
    name = "retry";

    on_before_llm = None;

    on_after_llm = None;

    on_before_tool = None;

    on_after_tool = None;

    on_error = Some (fun conv (err : error_category) ->
      let key = Hashtbl.hash conv in
      let current = match Hashtbl.find_opt attempts key with
        | Some n -> n
        | None -> 0
      in
      if current < effective_policy.max_attempts && is_retryable effective_policy.retry_on err then begin
        let next = current + 1 in
        Hashtbl.replace attempts key next;
        let delay = compute_delay effective_policy next in
        Some (Error {
          category = err;
          message = Printf.sprintf "Retrying (attempt %d/%d)..." next effective_policy.max_attempts;
          retryable = true;
          metadata = [
            ("attempt", `Int next);
            ("delay", `Float delay);
          ];
        })
      end else begin
        Hashtbl.remove attempts key;
        None
      end
    );
  }