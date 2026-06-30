open Types

type render_context = {
  agent_id : string;
  runtime_id : string;
  user_variables : (string * Yojson.Safe.t) list;
  available_tools : string list;
}

let extract_variables template =
  let len = String.length template in
  let vars = ref [] in
  let i = ref 0 in
  while !i < len - 2 do
    if template.[!i] = '{' && template.[!i + 1] = '{' then begin
      let start = !i + 2 in
      let j = ref start in
      while !j < len && template.[!j] <> '}' do incr j done;
      if !j < len - 1 && template.[!j] = '}' && template.[!j + 1] = '}' then
        let var_name = String.sub template start (!j - start) in
        let var_name = String.trim var_name in
        if var_name <> "" && not (List.mem var_name !vars) then
          vars := var_name :: !vars;
      i := !j + 2
    end else
      incr i
  done;
  List.rev !vars

let json_to_str = function
  | `String s -> s
  | v -> Yojson.Safe.to_string v

let resolve_variable name context builtins =
  match List.assoc_opt name builtins with
  | Some v -> Ok (json_to_str v)
  | None ->
    match List.assoc_opt name context.user_variables with
    | Some v -> Ok (json_to_str v)
    | None ->
      Result.Error (Types.Invalid_input (Printf.sprintf "Unknown template variable: %s" name))

let iso8601_now () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

let check_missing required all_var_names =
  List.filter (fun r -> not (List.mem r all_var_names)) required

let render ~template ~variables ~required ~context =
  let builtins = [
    ("current_time", `String (iso8601_now ()));
    ("agent_id", `String context.agent_id);
    ("runtime_id", `String context.runtime_id);
    ("available_tools", `List (List.map (fun n -> `String n) context.available_tools));
    ("user_variables", `Assoc context.user_variables);
  ] in
  let all_vars = builtins @ variables in
  let _ = extract_variables template in
  let all_var_names = List.concat_map (fun (k, _) -> [k]) all_vars in
  let missing = check_missing required all_var_names in
  if missing <> [] then
    Result.Error (Types.Invalid_input (Printf.sprintf "Missing required variables: %s"
      (String.concat ", " missing)))
  else begin
    let len = String.length template in
    let buf = Buffer.create (len * 2) in
    let i = ref 0 in
    let result = ref (Ok ()) in
    while !i < len && !result = Ok () do
      if !i < len - 2 && template.[!i] = '{' && template.[!i + 1] = '{' then begin
        let start = !i + 2 in
        let j = ref start in
        while !j < len && template.[!j] <> '}' do incr j done;
        if !j < len - 1 && template.[!j] = '}' && template.[!j + 1] = '}' then
          let var_name = String.sub template start (!j - start) in
          let var_name = String.trim var_name in
          (match resolve_variable var_name context all_vars with
           | Ok v -> Buffer.add_string buf v
           | Error e -> result := Error e);
        i := !j + 2
      end else begin
        Buffer.add_char buf template.[!i];
        incr i
      end
    done;
    (match !result with
     | Error _ as e -> e
     | Ok () -> Ok (Buffer.contents buf))
  end

let effective_system_prompt agent ~runtime_id =
  match agent.system_prompt_template with
  | None -> Ok (prompt_text agent.system_prompt)
  | Some tpl ->
    let context = {
      agent_id = agent.id;
      runtime_id;
      user_variables = [];
      available_tools = List.map (fun (td : tool_descriptor) -> td.name) agent.tools;
    } in
    render ~template:tpl.template ~variables:[] ~required:tpl.required ~context
