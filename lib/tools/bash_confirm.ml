open Types

let make_hook (config : bash_confirm_config) : Hook.tool_call_hook =
  fun (ctx : Hook.tool_call_context) ->
    if ctx.tool_name <> "bash" then Hook.Allow
    else begin
      let input_str = Yojson.Safe.to_string ctx.input in
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
        if not ctx.has_ui then
          Hook.Block { reason = "Bash command requires confirmation but no UI available" }
        else begin
          Printf.eprintf "Allow bash command? [y/N]: %!";
          flush stderr;
          try
            match input_line stdin with
            | s when String.length s > 0 && (s.[0] = 'y' || s.[0] = 'Y') ->
              Hook.Allow
            | _ -> Hook.Block { reason = "User denied bash command" }
          with End_of_file ->
            Hook.Block { reason = "User denied bash command (EOF)" }
        end
    end
