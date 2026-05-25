open Types

(* -------------------------------------------------------------------------- *)
(* §3.2 Middleware chain — Russian Doll composition                           *)
(* -------------------------------------------------------------------------- *)

let apply_before_llm hooks conv next =
  List.fold_right (fun hook acc ->
    fun c ->
      match hook.on_before_llm with
      | Some f ->
        (match f c with Some c' -> acc c' | None -> acc c)
      | None -> acc c
  ) hooks next conv

let apply_after_llm hooks resp next =
  List.fold_right (fun hook acc ->
    fun r ->
      match hook.on_after_llm with
      | Some f ->
        (match f r with Some r' -> acc r' | None -> acc r)
      | None -> acc r
  ) hooks next resp

let apply_before_tool hooks call next =
  List.fold_right (fun hook acc ->
    fun c ->
      match hook.on_before_tool with
      | Some f ->
        (match f c with Some c' -> acc c' | None -> acc c)
      | None -> acc c
  ) hooks next call

let apply_after_tool hooks (call, result) next =
  List.fold_right (fun hook acc ->
    fun (c, r) ->
      match hook.on_after_tool with
      | Some f ->
        (match f (c, r) with Some r' -> acc (c, r') | None -> acc (c, r))
      | None -> acc (c, r)
  ) hooks next (call, result)

let apply_on_error hooks err next =
  List.fold_right (fun hook acc ->
    fun e ->
      match hook.on_error with
      | Some f ->
        (match f e with Some r -> r | None -> acc e)
      | None -> acc e
  ) hooks next err

(* -------------------------------------------------------------------------- *)
(* §3.3 Tool pipeline                                                         *)
(* -------------------------------------------------------------------------- *)

let find_tool agent tool_name =
  List.find_opt (fun tb -> tb.name = tool_name) agent.tools

let execute_tool token binding input middleware =
  let call = { id = Task_id.create (); name = binding.name; arguments = input } in
  apply_before_tool middleware call (fun call' ->
    apply_after_tool middleware (call', binding.handler input token) (fun (_, result) ->
      result
    )
  )

(* -------------------------------------------------------------------------- *)
(* §3.4 Agent executor — ReAct loop                                           *)
(* -------------------------------------------------------------------------- *)

let make_conversation agent user_message =
  let sys = { role = System; content = Some agent.system_prompt; tool_calls = None; tool_call_id = None; name = None } in
  let usr = { role = User; content = Some user_message; tool_calls = None; tool_call_id = None; name = None } in
  { messages = [ sys; usr ]; metadata = [] }

let add_assistant_message conv resp =
  let msg = {
    role = Assistant;
    content = resp.text;
    tool_calls = resp.tool_calls;
    tool_call_id = None;
    name = None;
  } in
  { conv with messages = conv.messages @ [ msg ] }

let add_tool_result_message conv call result =
  let content = match result with
    | Success json -> Yojson.Safe.to_string json
    | Error e -> e.message
  in
  let msg = {
    role = Tool;
    content = Some content;
    tool_calls = None;
    tool_call_id = Some call.id;
    name = Some call.name;
  } in
  { conv with messages = conv.messages @ [ msg ] }

let run_agent token agent user_message llm_service =
  let (module Llm : LLM_SERVICE with type t = 'l) = llm_service in
  let rec loop conv iterations =
    if iterations >= agent.max_iterations then
      Error (Internal "Max iterations exceeded")
    else begin
      Cancellation.check_cancel token;
      let conv = apply_before_llm agent.middleware conv (fun c -> c) in
      match Llm.complete agent.model conv with
      | Error err -> Error err
      | Ok resp ->
        let resp = apply_after_llm agent.middleware resp (fun r -> r) in
        match resp.tool_calls with
        | Some calls when calls <> [] ->
          let conv = add_assistant_message conv resp in
          let results = List.map (fun call ->
            match find_tool agent call.name with
            | None ->
              let err = Error {
                category = Invalid_input (Printf.sprintf "Tool not found: %s" call.name);
                message = "Tool not found";
                retryable = false;
                metadata = [];
              } in
              (call, err)
            | Some binding ->
              (call, execute_tool token binding call.arguments agent.middleware)
          ) calls in
          let conv = List.fold_left (fun conv (call, result) ->
            add_tool_result_message conv call result
          ) conv results in
          loop conv (iterations + 1)
        | _ ->
          match resp.finish_reason with
          | Max_tokens ->
            if iterations + 1 >= agent.max_iterations then Error (Internal "Max iterations exceeded")
            else loop conv (iterations + 1)
          | _ -> Ok resp
    end
  in
  let conv = make_conversation agent user_message in
  loop conv 0
