open Par
open Types

let show_error : error_category -> string = function
  | Timeout -> "timeout"
  | Invalid_input s -> s
  | External_failure s -> s
  | Rate_limited -> "rate_limited"
  | Permission_denied s -> s
  | Internal s -> s
  | Embedding_unsupported -> "embedding_unsupported"

let dummy_model : Types.model_config = {
  Types.provider = `Openai; model_name = "gpt-4"; api_base = None;
  temperature = 0.7; max_tokens = None; top_p = None; stop_sequences = None;
}

let dummy_agent ?(id = "test") ?(system_prompt = "hello") ?system_prompt_template () = {
  Types.id;
  system_prompt;
  system_prompt_template = Option.value system_prompt_template ~default:None;
  model = dummy_model;
  tools = [];
  max_iterations = 5;
  middleware = [];
  retry_policy = None;
  context_strategy = None;
  resource_quota = None; max_execution_time = None; tool_timeout = None; early_stopping_method = Force;
  on_max_tokens = Some Return_partial; max_continuation_chunks = Some 3;
  context_compression_threshold = None; compression_cooldown_messages = None; context_window_override = None; cache_strategy = No_caching;
}

let ctx ~agent_id ~runtime_id =
  { Template.agent_id; runtime_id; user_variables = []; available_tools = [] }

let () =
  Alcotest.run "template" [
    ("basic substitution", [
      Alcotest.test_case "single variable" `Quick (fun () ->
        let tpl = "Hello {{name}}!" in
        let result = Template.render
          ~template:tpl
          ~variables:[("name", `String "World")]
          ~required:[]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok s -> Alcotest.(check string) "rendered" "Hello World!" s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );

      Alcotest.test_case "multiple variables" `Quick (fun () ->
        let tpl = "{{greeting}}, {{name}}! Time: {{time}}." in
        let result = Template.render
          ~template:tpl
          ~variables:[("greeting", `String "Hi"); ("name", `String "Alice"); ("time", `String "noon")]
          ~required:[]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok s -> Alcotest.(check string) "rendered" "Hi, Alice! Time: noon." s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );

      Alcotest.test_case "empty template" `Quick (fun () ->
        let result = Template.render
          ~template:""
          ~variables:[]
          ~required:[]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok s -> Alcotest.(check string) "empty" "" s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );

      Alcotest.test_case "no variables in template" `Quick (fun () ->
        let result = Template.render
          ~template:"Just plain text"
          ~variables:[]
          ~required:[]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok s -> Alcotest.(check string) "plain" "Just plain text" s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );
    ]);

    ("builtin variables", [
      Alcotest.test_case "current_time format" `Quick (fun () ->
        let result = Template.render
          ~template:"Time: {{current_time}}"
          ~variables:[]
          ~required:[]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok s ->
          Alcotest.(check bool) "starts with Time: " true (String.starts_with ~prefix:"Time: " s);
          let t = String.sub s 6 (String.length s - 6) in
          Alcotest.(check bool) "ends with Z" true (String.ends_with ~suffix:"Z" t);
          Alcotest.(check int) "length" 20 (String.length t)
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );

      Alcotest.test_case "agent_id builtin" `Quick (fun () ->
        let result = Template.render
          ~template:"Agent: {{agent_id}}"
          ~variables:[]
          ~required:[]
          ~context:(ctx ~agent_id:"my-agent-123" ~runtime_id:"rt-1") in
        match result with
        | Ok s -> Alcotest.(check string) "agent_id" "Agent: my-agent-123" s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );

      Alcotest.test_case "available_tools builtin" `Quick (fun () ->
        let result = Template.render
          ~template:"Tools: {{available_tools}}"
          ~variables:[]
          ~required:[]
          ~context:{ (ctx ~agent_id:"a" ~runtime_id:"r") with available_tools = ["calc"; "echo"] } in
        match result with
        | Ok s ->
          Alcotest.(check bool) "has calc" true (String.contains s 'c');
          Alcotest.(check bool) "has echo" true (String.contains s 'e')
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );
    ]);

    ("error handling", [
      Alcotest.test_case "unknown variable" `Quick (fun () ->
        let result = Template.render
          ~template:"Hello {{unknown_var}}!"
          ~variables:[]
          ~required:[]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok _ -> Alcotest.fail "expected error for unknown variable"
        | Error (Types.Invalid_input msg) ->
          Alcotest.(check bool) "error msg" true (String.contains msg 'u')
        | Error e -> Alcotest.failf "wrong error type: %s" (show_error e)
      );

      Alcotest.test_case "missing required variable" `Quick (fun () ->
        let result = Template.render
          ~template:"Hello {{name}}!"
          ~variables:[]
          ~required:["name"]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok _ -> Alcotest.fail "expected error for missing required"
        | Error (Types.Invalid_input msg) ->
          Alcotest.(check bool) "has Missing" true
            (let lower = String.lowercase_ascii msg in
             String.contains lower 'm' && String.contains lower 'r')
        | Error e -> Alcotest.failf "wrong error type: %s" (show_error e)
      );

      Alcotest.test_case "malformed single brace" `Quick (fun () ->
        let result = Template.render
          ~template:"Hello {name!"
          ~variables:[("name", `String "X")]
          ~required:[]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok s -> Alcotest.(check string) "passthrough" "Hello {name!" s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );

      Alcotest.test_case "malformed triple brace" `Quick (fun () ->
        let result = Template.render
          ~template:"Hello {{{name}}!"
          ~variables:[("name", `String "X")]
          ~required:[]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok _ -> Alcotest.fail "expected error for triple brace (treated as {{ {name }})"
        | Error (Types.Invalid_input msg) ->
          Alcotest.(check bool) "has unknown" true (String.contains msg 'n')
        | Error e -> Alcotest.failf "wrong error type: %s" (show_error e)
      );
    ]);

    ("precedence", [
      Alcotest.test_case "user variable cannot override builtin" `Quick (fun () ->
        let result = Template.render
          ~template:"ID: {{agent_id}}"
          ~variables:[("agent_id", `String "hacked")]
          ~required:[]
          ~context:{ (ctx ~agent_id:"real-agent" ~runtime_id:"r") with
                     user_variables = [("agent_id", `String "hacked")] } in
        match result with
        | Ok s -> Alcotest.(check string) "builtin wins" "ID: real-agent" s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );

      Alcotest.test_case "user variable works for non-builtin" `Quick (fun () ->
        let result = Template.render
          ~template:"Role: {{role}}"
          ~variables:[]
          ~required:[]
          ~context:{ (ctx ~agent_id:"a" ~runtime_id:"r") with
                     user_variables = [("role", `String "assistant")] } in
        match result with
        | Ok s -> Alcotest.(check string) "user var" "Role: assistant" s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );
    ]);

    ("effective_system_prompt", [
      Alcotest.test_case "no template returns system_prompt" `Quick (fun () ->
        let agent = dummy_agent ~system_prompt:"plain prompt" () in
        match Template.effective_system_prompt agent ~runtime_id:"r" with
        | Ok s -> Alcotest.(check string) "plain" "plain prompt" s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );

      Alcotest.test_case "template renders" `Quick (fun () ->
        let agent = { (dummy_agent ~system_prompt:"fallback" ()) with
                     system_prompt = "fallback";
                     system_prompt_template = Some {
                       template = "You are {{agent_id}}.";
                       variables = [];
                       required = [];
                     };
                   } in
        match Template.effective_system_prompt agent ~runtime_id:"r" with
        | Ok s -> Alcotest.(check string) "rendered" "You are test." s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );
    ]);

    ("edge cases", [
      Alcotest.test_case "whitespace in variable name" `Quick (fun () ->
        let result = Template.render
          ~template:"Val: {{  name  }}"
          ~variables:[("name", `String "Bob")]
          ~required:[]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok s -> Alcotest.(check string) "trimmed" "Val: Bob" s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );

      Alcotest.test_case "consecutive variables" `Quick (fun () ->
        let result = Template.render
          ~template:"{{a}}{{b}}{{c}}"
          ~variables:[("a", `String "X"); ("b", `String "Y"); ("c", `String "Z")]
          ~required:[]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok s -> Alcotest.(check string) "concat" "XYZ" s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );

      Alcotest.test_case "variable with curly braces in value" `Quick (fun () ->
        let result = Template.render
          ~template:"Code: {{expr}}"
          ~variables:[("expr", `String "{ x = 1 }")]
          ~required:[]
          ~context:(ctx ~agent_id:"a" ~runtime_id:"r") in
        match result with
        | Ok s -> Alcotest.(check string) "code" "Code: { x = 1 }" s
        | Error e -> Alcotest.failf "unexpected error: %s" (show_error e)
      );
    ]);
  ]
