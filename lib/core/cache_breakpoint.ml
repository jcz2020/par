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

(* User-facing cache marking API (ROADMAP B.3).
   mark_tool: sets cache_control on a tool_descriptor, marking it for caching.
   mark_message: sets cache_control on the LAST content_block of a message. *)

let mark_tool ~ttl (td : Types.tool_descriptor) : Types.tool_descriptor =
  { td with Types.cache_control = Some { Types.type_ = `Ephemeral; ttl = Some ttl } }

let mark_message ~ttl (msg : Types.message) : Types.message =
  let cc = Some { Types.type_ = `Ephemeral; ttl = Some ttl } in
  let blocks = msg.Types.content_blocks in
  match List.rev blocks with
  | [] -> msg  (* empty content_blocks → no-op *)
  | last :: rest ->
    let marked_last = match last with
      | Types.Text_block b -> Types.Text_block { b with cache_control = cc }
      | Types.Tool_use_block b -> Types.Tool_use_block { b with cache_control = cc }
      | Types.Tool_result_block b -> Types.Tool_result_block { b with cache_control = cc }
      | Types.Image_block b -> Types.Image_block { b with cache_control = cc }
    in
    let new_blocks = List.rev (marked_last :: rest) in
    { msg with Types.content_blocks = new_blocks }
