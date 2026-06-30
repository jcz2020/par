open Types

type breakpoint = {
  location : breakpoint_location;
  ttl : cache_ttl;
  estimated_tokens : int;
  priority : int;
}

type breakpoint_plan = {
  used : breakpoint list;
  dropped : (breakpoint * drop_reason) list;
}

let plan_breakpoints ?max_override (svc : llm_service) (candidates : breakpoint list) =
  let capability = match svc.cache_control_fn with
    | Some fn -> fn ()
    | None -> { supported_ttls = []; max_breakpoints = 0 }
  in
  let max_bp = Option.value max_override ~default:capability.max_breakpoints in
  if max_bp <= 0 then
    { used = []
    ; dropped = List.map (fun bp -> (bp, Unsupported_by_provider)) candidates }
  else
    let sorted = List.sort (fun a b -> compare b.priority a.priority) candidates in
    let rec split n acc rest =
      if n <= 0 then
        (List.rev acc, List.map (fun bp -> (bp, Over_budget)) rest)
      else
        match rest with
        | [] -> (List.rev acc, [])
        | x :: xs -> split (n - 1) (x :: acc) xs
    in
    let used, dropped = split max_bp [] sorted in
    { used; dropped }
