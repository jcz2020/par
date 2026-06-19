(* Manual smoke test for WU-5: Mock_provider.complete_structured_fn *)
open Par
open Par.Mock_provider

let model : Types.model_config = {
  provider = `Openai;
  model_name = "test-model";
  api_base = None;
  temperature = 0.7;
  max_tokens = None;
  top_p = None;
  stop_sequences = None;
}

let conv : Types.conversation = { messages = []; metadata = [] }

let dump label (r : (Types.llm_response, Types.error_category) result) =
  match r with
  | Ok resp ->
    Printf.printf "%s -> Ok { text = %s; tool_calls = %s; finish_reason = %s; model = %S; usage.prompt = %d }\n"
      label
      (match resp.text with Some t -> Printf.sprintf "Some %S" t | None -> "None")
      (match resp.tool_calls with Some _ -> "Some _" | None -> "None")
      (match resp.finish_reason with Stop -> "Stop" | Tool_calls -> "Tool_calls")
      resp.model
      resp.usage.prompt_tokens
  | Error _ ->
    Printf.printf "%s -> Error _\n" label

let () =
  Printf.printf "===== WU-5 manual smoke test =====\n";

  let schema : Yojson.Safe.t = `Assoc [
    "type", `String "object";
    "properties", `Assoc [
      "name", `Assoc ["type", `String "string"];
      "age",  `Assoc ["type", `String "integer"];
    ];
  ] in
  let (svc1, _h1) = create [Text "irrelevant"] in
  (match svc1.complete_structured_fn with
   | None -> Printf.printf "FAIL: complete_structured_fn is None\n"
   | Some f -> dump "default-synth (name+age)" (f model [] conv schema));

  let schema_all : Yojson.Safe.t = `Assoc [
    "type", `String "object";
    "properties", `Assoc [
      "s", `Assoc ["type", `String "string"];
      "i", `Assoc ["type", `String "integer"];
      "n", `Assoc ["type", `String "number"];
      "b", `Assoc ["type", `String "boolean"];
      "a", `Assoc ["type", `String "array"];
      "o", `Assoc ["type", `String "object"];
      "u", `Assoc ["type", `String "unknown"];
    ];
  ] in
  let (svc2, _h2) = create [Text "irrelevant"] in
  (match svc2.complete_structured_fn with
   | None -> ()
   | Some f -> dump "default-synth (all types)" (f model [] conv schema_all));

  let schema_empty : Yojson.Safe.t = `Assoc [] in
  let (svc3, _h3) = create [Text "irrelevant"] in
  (match svc3.complete_structured_fn with
   | None -> ()
   | Some f -> dump "default-synth (empty schema)" (f model [] conv schema_empty));

  let schema_prim : Yojson.Safe.t = `String "string" in
  let (svc4, _h4) = create [Text "irrelevant"] in
  (match svc4.complete_structured_fn with
   | None -> ()
   | Some f -> dump "default-synth (non-object schema)" (f model [] conv schema_prim));

  let canned : Yojson.Safe.t = `Assoc [
    ("custom", `String "value");
    ("count", `Int 7);
  ] in
  let (svc5, _h5) = create ~structured_response:canned [Text "irrelevant"] in
  (match svc5.complete_structured_fn with
   | None -> Printf.printf "FAIL: complete_structured_fn is None on override svc\n"
   | Some f -> dump "override (custom JSON, schema=irrelevant)" (f model [] conv schema));

  let (svc6, _h6) = create ~structured_response:(`List [`Int 1; `Int 2; `Int 3]) [Text "x"] in
  (match svc6.complete_structured_fn with
   | None -> ()
   | Some f -> dump "override (array, schema=Null)" (f model [] conv `Null));

  Printf.printf "===== done =====\n"