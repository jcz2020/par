open Types

type rate_limit_config = {
  max_requests : int;
  window : float;
}

let default_rate_limit_config : rate_limit_config = {
  max_requests = 60;
  window = 60.0;
}

let rate_limit ?(config = default_rate_limit_config) () : middleware_hook =
  let max_requests = config.max_requests in
  let window_seconds = config.window in
  let timestamps : float list ref = ref [] in
  let mutex = Eio.Mutex.create () in

  let prune now =
    let cutoff = now -. window_seconds in
    List.filter (fun ts -> ts > cutoff) !timestamps
  in

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
          Some { conv with
            metadata = ("rate_limited", `Bool true) :: conv.metadata }
        else begin
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
