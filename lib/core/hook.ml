(* Tool call hook mechanism — Allow/Block/Modify decision chain.
   Exceptions in hooks fail-closed (Block). *)

type reason = string

type tool_call_decision =
  | Allow
  | Block of { reason : string }
  | Modify of { input : Yojson.Safe.t }

type tool_call_context = {
  tool_name : string;
  tool_call_id : string;
  input : Yojson.Safe.t;
  has_ui : bool;
}

type tool_call_hook = tool_call_context -> tool_call_decision

type chain_result =
  | Final_allow
  | Final_block of reason
  | Final_modify of Yojson.Safe.t

let run_chain (hooks : tool_call_hook list) (ctx : tool_call_context) : chain_result =
  let rec aux current_input = function
    | [] ->
      (match current_input with
       | Some i -> Final_modify i
       | None -> Final_allow)
    | hook :: rest ->
      let ctx' = { ctx with input = (match current_input with Some i -> i | None -> ctx.input) } in
      let result = hook ctx' in
      (match result with
       | Allow -> aux current_input rest
       | Block { reason } -> Final_block reason
       | Modify { input = new_input } -> aux (Some new_input) rest)
  in
  aux None hooks
