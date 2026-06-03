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

val run_chain : tool_call_hook list -> tool_call_context -> chain_result
