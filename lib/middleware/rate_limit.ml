open Types

(* Token-bucket rate limiter.
   Tracks request timestamps in a sliding window and signals when the
   configured limit is exceeded.  Thread-safe via Eio.Mutex. *)

let rate_limit ?(max_requests = 60) ?(window_seconds = 60.0) () : middleware_hook =
  let timestamps : float list ref = ref [] in
  let mutex = Eio.Mutex.create () in

  (* Remove timestamps older than the sliding window *)
  let prune now =
    let cutoff = now -. window_seconds in
    List.filter (fun ts -> ts > cutoff) !timestamps
  in

  (* Find the oldest timestamp in the pruned list *)
  let oldest ts_list =
    List.fold_left (fun _ x -> x) 0.0 ts_list
  in

  {
    name = "rate_limit";

    on_before_llm = Some (fun conv ->
      let now = Unix.gettimeofday () in
      Eio.Mutex.use_rw ~protect:false mutex (fun () ->
        timestamps := prune now;
        if List.length !timestamps >= max_requests then
          (* Window full — mark conversation as rate-limited *)
          Some { conv with
            metadata = ("rate_limited", `Bool true) :: conv.metadata }
        else begin
          (* Record this request *)
          timestamps := now :: !timestamps;
          None
        end
      )
    );

    on_after_llm = None;

    on_before_tool = None;

    on_after_tool = None;

    on_error = Some (fun err ->
      match err with
      | Rate_limited ->
        let now = Unix.gettimeofday () in
        Eio.Mutex.use_ro mutex (fun () ->
          let valid = prune now in
          let retry_after =
            match valid with
            | [] -> window_seconds
            | _ ->
              let oldest_ts = oldest valid in
              Float.max 0.0 (oldest_ts +. window_seconds -. now)
          in
          Some (Error {
            category = Rate_limited;
            message = Printf.sprintf
              "Rate limit exceeded, retry after %.1fs" retry_after;
            retryable = true;
            metadata = [("retry_after", `Float retry_after)];
          })
        )
      | _ -> None
    );
  }
