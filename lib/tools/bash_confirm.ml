open Types

let make_hook ?confirm_fn (config : bash_confirm_config) : Hook.tool_call_hook =
  fun (ctx : Hook.tool_call_context) ->
    if ctx.tool_name <> "bash" then Hook.Allow
    else begin
      let input_str = Yojson.Safe.to_string ctx.input in
      let command_str = match ctx.input with
        | `Assoc fields ->
          (match List.assoc_opt "command" fields with
           | Some (`String s) -> s
           | _ -> input_str)
        | _ -> input_str
      in
      let effective_policy = ref config.default_policy in
      List.iter (fun (pattern, policy) ->
        try
          let re = Str.regexp pattern in
          if Str.string_match re input_str 0 then
            effective_policy := policy
        with _ -> ()
      ) config.patterns;
      match !effective_policy with
      | `Never -> Hook.Allow
      | `Always | `Pattern ->
        let allowed =
          match confirm_fn with
          | Some fn -> fn command_str
          | None ->
            if not ctx.has_ui then false
            else begin
              Printf.eprintf "Allow bash command? [y/N]: %!";
              flush stderr;
              try
                match input_line stdin with
                | s when String.length s > 0 && (s.[0] = 'y' || s.[0] = 'Y') -> true
                | _ -> false
              with End_of_file -> false
            end
        in
        if allowed then Hook.Allow
        else Hook.Block { reason = "User denied bash command" }
    end
