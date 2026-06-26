(* Mock LLM Provider — deterministic/scripted responses for testing *)

open Types

(* --- Error formatting --- *)

let format_error : error_category -> string = function
  | Types.Timeout -> "timeout"
  | Types.Invalid_input s -> s
  | Types.External_failure s -> s
  | Types.Rate_limited -> "rate_limited"
  | Types.Permission_denied s -> s
  | Types.Internal s -> s
  | Types.Embedding_unsupported -> "embedding_unsupported"

(* --- Call history for test assertions --- *)

type call_record = {
  model : model_config;
  tools : tool_descriptor list;
  conversation : conversation;
  timestamp : float;
}

type call_history = {
  mutable complete_calls : call_record list;
  mutable stream_calls : call_record list;
  mutable close_calls : int;
}

let create_history () = {
  complete_calls = [];
  stream_calls = [];
  close_calls = 0;
}

let call_count h =
  List.length h.complete_calls + List.length h.stream_calls

let last_complete_call h =
  match h.complete_calls with [] -> None | x :: _ -> Some x

let nth_complete_call h n =
  try Some (List.nth h.complete_calls n) with Invalid_argument _ -> None

let last_stream_call h =
  match h.stream_calls with [] -> None | x :: _ -> Some x

let nth_stream_call h n =
  try Some (List.nth h.stream_calls n) with Invalid_argument _ -> None

type embed_call_record = {
  inputs : string list;
  timestamp : float;
}
[@@@warning "-32-69"]

type embed_call_history = {
  mutable embed_calls : embed_call_record list;
}

let create_embed_history () = { embed_calls = [] }

let embed_call_count h = List.length h.embed_calls

let last_embed_call h =
  match h.embed_calls with [] -> None | x :: _ -> Some x

let nth_embed_call h n =
  try Some (List.nth h.embed_calls n) with Invalid_argument _ -> None

(* --- Scripted response variant --- *)

type scripted_response =
  | Text of string
  | With_tool_calls of { text : string option; calls : tool_call list }
  | Error of error_category

(* --- Configuration --- *)

type mock_config = {
  responses : scripted_response list;
  delay : float option;  (* Optional simulated delay in seconds *)
  usage : usage_stats;
  model_name : string;
}

let default_usage = { prompt_tokens = 10; completion_tokens = 20; total_tokens = 30 }

let default_model = "mock-llm"

(* --- Internal state --- *)

type mock_state = {
  config : mock_config;
  history : call_history;
  mutable cursor : int;
}

(* Convert scripted_response to llm_response *)
let to_response resp config =
  match resp with
  | Text t ->
    { text = Some t; tool_calls = None; finish_reason = Stop;
      usage = config.usage; model = config.model_name }
  | With_tool_calls { text; calls } ->
    { text; tool_calls = Some calls; finish_reason = Tool_calls;
      usage = config.usage; model = config.model_name }
  | Error e ->
    raise (Failure (format_error e))

(* Get next response, advancing cursor *)
let get_next state =
  match state.config.responses with
  | [] ->
    (* No scripted responses: return a default *)
    { text = Some "mock"; tool_calls = None; finish_reason = Stop;
      usage = state.config.usage; model = state.config.model_name }
  | [single] ->
    (* Single response: always return it without advancing *)
    to_response single state.config
  | _ ->
    (* Multi-response: cycle through via cursor *)
    let idx = state.cursor in
    state.cursor <- (idx + 1) mod List.length state.config.responses;
    (try Some (List.nth state.config.responses idx) with Invalid_argument _ -> None)
    |> function
    | Some resp -> to_response resp state.config
    | None ->
      (* Fallback (should not happen with proper modulo) *)
      { text = Some "mock"; tool_calls = None; finish_reason = Stop;
        usage = state.config.usage; model = state.config.model_name }

(* Optional simulated delay *)
let maybe_delay = function
  | Some d when d > 0.0 -> Unix.sleepf d
  | _ -> ()

(* --- Count chunks for stream_complete --- *)

let count_chunks resp =
  let text_chunks = match resp.text with Some _ -> 1 | None -> 0 in
  let tool_chunks = match resp.tool_calls with
    | Some calls -> List.length calls * 2  (* start + delta per call *)
    | None -> 0
  in
  (* text + tool + usage + done *)
  text_chunks + tool_chunks + 2

(* --- Schema synthesis for structured output tests --- *)

let synthesize_from_schema (schema : Yojson.Safe.t) : Yojson.Safe.t =
  let default_for_type ty =
    match ty with
    | `String "string" -> `String ""
    | `String "integer" -> `Int 0
    | `String "number" -> `Float 0.0
    | `String "boolean" -> `Bool false
    | `String "array" -> `List []
    | `String "object" -> `Assoc []
    | `String "null" -> `Null
    | _ -> `Null
  in
  match schema with
  | `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String "object") ->
       (match List.assoc_opt "properties" fields with
        | Some (`Assoc props) ->
          let synthesized = List.map (fun (k, subschema) ->
            let default =
              match subschema with
              | `Assoc sf -> (match List.assoc_opt "type" sf with
                  | Some ty -> default_for_type ty
                  | None -> `Null)
              | _ -> `Null
            in
            (k, default)
          ) props in
          `Assoc synthesized
        | _ -> `Assoc [])
     | Some ty -> default_for_type ty
     | None -> `Assoc [])
  | _ -> `Null

(* --- Public API --- *)

let create ?(delay = None) ?(usage = default_usage) ?(model_name = default_model)
    ?structured_response responses =
  let state = {
    config = { responses; delay; usage; model_name };
    history = create_history ();
    cursor = 0;
  } in
  let service = {
    complete_fn = (fun model tools conv ->
      maybe_delay state.config.delay;
      let record = {
        model; tools; conversation = conv;
        timestamp = Unix.gettimeofday ();
      } in
      state.history.complete_calls <- record :: state.history.complete_calls;
      try Ok (get_next state)
      with Failure msg -> Error (Internal msg)
    );
    stream_fn = (fun model tools conv _stream_config cb ->
      maybe_delay state.config.delay;
      let record = {
        model; tools; conversation = conv;
        timestamp = Unix.gettimeofday ();
      } in
      state.history.stream_calls <- record :: state.history.stream_calls;
      (try
         let resp = get_next state in
         (* 1. Emit text as Text_delta *)
         (match resp.text with
          | Some t -> cb (Text_delta { text = t })
          | None -> ());
         (* 2. Emit tool calls: start then delta for each *)
         (match resp.tool_calls with
          | Some calls ->
            List.iter (fun (tc : tool_call) ->
              cb (Tool_call_start { tool_call_id = tc.id; name = tc.name });
              cb (Tool_call_delta {
                tool_call_id = tc.id;
                args_json = Yojson.Safe.to_string tc.arguments;
              })
            ) calls
          | None -> ());
         (* 3. Emit usage update *)
         cb (Usage_update resp.usage);
         (* 4. Emit done *)
         cb (Done { finish_reason = resp.finish_reason });
         Ok {
           final_usage = resp.usage;
           finish_reason = resp.finish_reason;
           chunks_received = count_chunks resp;
         }
       with Failure msg -> Error (Internal msg))
    );
    close_fn = (fun () ->
      state.history.close_calls <- state.history.close_calls + 1
    );
    complete_structured_fn = Some (fun model tools conv response_schema ->
      maybe_delay state.config.delay;
      let record = {
        model; tools; conversation = conv;
        timestamp = Unix.gettimeofday ();
      } in
      state.history.complete_calls <- record :: state.history.complete_calls;
      let json = match structured_response with
        | Some j -> j
        | None -> synthesize_from_schema response_schema
      in
      Ok { text = Some (Yojson.Safe.to_string json);
           tool_calls = None; finish_reason = Stop;
           usage = state.config.usage; model = state.config.model_name }
    );
    list_models_fn = None;
  } in
  (service, state.history)

let vector_for_input msg =
  let seed = Hashtbl.hash msg in
  let rng = Random.State.make [| seed |] in
  Array.init 1536 (fun _ -> Random.State.float rng 2.0 -. 1.0)

let mock_embed_service () =
  let history = create_embed_history () in
  let service = {
    embed_fn = (fun inputs ->
      let record = { inputs; timestamp = Unix.gettimeofday () } in
      history.embed_calls <- record :: history.embed_calls;
      Ok (List.map vector_for_input inputs)
    );
    close_fn = ignore;
  } in
  (service, history)
