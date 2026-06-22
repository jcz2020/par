(* par_capi.ml — OCaml side of the C FFI bridge.
     Persistent Eio domain per Runtime, work-loop dispatch. *)

open Par
let () = ()
(* Force module load order: Health, Metrics, Runtime, Hook are referenced. *)

let json_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c -> match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c < 32 ->
      Printf.bprintf buf "\\u%04x" (Char.code c)
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let error_json msg =
  Printf.sprintf "{\"error\": \"%s\"}" (json_escape msg)

(* Direct fd write so debug output is visible from inside an Eio domain
   (Eio redirects stderr buffers per-domain). *)
let fd_log s =
  if Sys.getenv_opt "PAR_FFI_DEBUG" <> None then begin
    let msg = s ^ "\n" in
    ignore (Unix.write_substring Unix.stderr msg 0 (String.length msg))
  end

(* -------------------------------------------------------------------------- *)
(* Per-runtime state. Cross-domain-safe: only stdlib primitives.              *)
(* -------------------------------------------------------------------------- *)

(* Per-call result slot: cross-domain-safe single-value channel.
   The callback allocates a slot, enqueues the work item that holds
   the slot, then waits. The work loop fills the slot and signals. *)
type 'a result_slot = {
  slot_mutex : Mutex.t;
  slot_cond : Condition.t;
  mutable slot_value : 'a option;
}

let create_slot () = {
  slot_mutex = Mutex.create ();
  slot_cond = Condition.create ();
  slot_value = None;
}

let slot_put slot v =
  Mutex.lock slot.slot_mutex;
  slot.slot_value <- Some v;
  Condition.signal slot.slot_cond;
  Mutex.unlock slot.slot_mutex

let slot_take slot =
  Mutex.lock slot.slot_mutex;
  while slot.slot_value = None do
    Condition.wait slot.slot_cond slot.slot_mutex
  done;
  let v = Option.get slot.slot_value in
  Mutex.unlock slot.slot_mutex;
  v

(* Work item: the closure is stored existentially (Obj.t) so the queue
   is monomorphic. The dispatch helper reconstructs the call by
   downcasting the closure at runtime. *)
type work_item = {
  work : Obj.t;  (* holds runtime -> env -> Obj.t closure *)
  result : Obj.t result_slot;
}

type runtime_state = {
  work_queue : work_item Queue.t;
  work_mutex : Mutex.t;
  work_cond : Condition.t;
}

let states : (int, runtime_state) Hashtbl.t = Hashtbl.create 8
let domains : (int, unit Domain.t) Hashtbl.t = Hashtbl.create 8
let state_counter = ref 0

let alloc_state () =
  incr state_counter;
  let id = !state_counter in
  let state = {
    work_queue = Queue.create ();
    work_mutex = Mutex.create ();
    work_cond = Condition.create ();
  } in
  Hashtbl.add states id state;
  id

let get_state id =
  try Some (Hashtbl.find states id)
  with Not_found -> None

let free_state id =
  Hashtbl.remove states id

(* Dispatch helper: enqueue work, wait for result. *)
let dispatch state_id (work_fn : Par.Runtime.runtime -> 'e -> Obj.t) : Obj.t =
  fd_log "[dispatch] enter";
  match get_state state_id with
  | None -> fd_log "[dispatch] state not found"; Obj.repr None
  | Some state ->
    let result_slot = create_slot () in
    fd_log "[dispatch] acquiring work_mutex";
    Mutex.lock state.work_mutex;
    fd_log "[dispatch] work_mutex acquired, pushing work";
    Queue.push { work = Obj.repr work_fn; result = result_slot } state.work_queue;
    Condition.signal state.work_cond;
    Mutex.unlock state.work_mutex;
    fd_log "[dispatch] work pushed, taking slot";
    let r = slot_take result_slot in
    fd_log "[dispatch] slot taken";
    r

(* Sentinel: when this appears at the front of the queue, the work loop
   shuts down. *)
let shutdown_sentinel : Obj.t = Obj.repr (fun (_rt : Par.Runtime.runtime) (_env : Obj.t) (_ : Obj.t) -> Obj.repr ())

(* Work loop: runs inside the persistent Eio domain. Captures rt and env
   lexically — never crosses domain boundary. *)
let rec work_loop rt env state =
  Mutex.lock state.work_mutex;
  let rec wait_for_work () =
    if Queue.is_empty state.work_queue then begin
      Condition.wait state.work_cond state.work_mutex;
      wait_for_work ()
    end
  in
  wait_for_work ();
  let item = Queue.pop state.work_queue in
  Mutex.unlock state.work_mutex;
  if item.work == shutdown_sentinel then begin
    fd_log "[work_loop] shutdown sentinel received, exiting"
  end else begin
    (try
       let fn : Par.Runtime.runtime -> _ -> Obj.t = Obj.obj item.work in
       let result = fn rt env in
       slot_put item.result result
     with ex ->
       fd_log ("[work_loop] work item raised: " ^ Printexc.to_string ex);
       slot_put item.result (Obj.repr None));
    work_loop rt env state
  end

(* -------------------------------------------------------------------------- *)
(* Service factories                                                          *)
(* -------------------------------------------------------------------------- *)

let default_llm_service : Par.Types.llm_service = {
  complete_fn = (fun _ _ _ -> Result.Error (Par.Types.Internal "LLM not initialized"));
  stream_fn = (fun _ _ _ _ _ -> Result.Error (Par.Types.Internal "LLM not initialized"));
  close_fn = ignore;
  complete_structured_fn = None;
}

let build_llm_from_provider provider_cfg net =
  let net_gen = (net :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
  match provider_cfg with
  | Par.Types.Openai { api_key; base_url; organization; embedding_model = _ } ->
    (match Par.Openai_provider.create (Par.Types.Openai { api_key; base_url; organization; embedding_model = None }) with
     | Ok t ->
       Par.Openai_provider.set_network t net_gen;
       Some {
         Par.Types.complete_fn = (fun mc tools conv -> Par.Openai_provider.complete t mc tools conv);
         stream_fn = (fun mc tools conv sc cb -> Par.Openai_provider.stream t mc tools conv sc cb);
         close_fn = (fun () -> Par.Openai_provider.close t);
         complete_structured_fn = None;
       }
     | Error _ -> None)
  | Par.Types.Ollama { base_url } ->
    let cfg = Par.Types.Openai { api_key = "ollama-no-auth"; base_url = Some (base_url ^ "/v1"); organization = None; embedding_model = None } in
    (match Par.Openai_provider.create cfg with
     | Ok t ->
       Par.Openai_provider.set_network t net_gen;
       Some {
         Par.Types.complete_fn = (fun mc tools conv -> Par.Openai_provider.complete t mc tools conv);
         stream_fn = (fun mc tools conv sc cb -> Par.Openai_provider.stream t mc tools conv sc cb);
         close_fn = (fun () -> Par.Openai_provider.close t);
         complete_structured_fn = None;
       }
     | Error _ -> None)
  | Par.Types.Anthropic _ ->
    fd_log "[llm] Anthropic provider not yet supported for LLM, skipping";
    None
  | Par.Types.Custom _ ->
    fd_log "[llm] Custom provider not supported, skipping";
    None

let build_embed_from_provider provider_cfg net =
  let net_gen = (net :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
  match provider_cfg with
  | Par.Types.Openai { api_key; base_url; organization; embedding_model } ->
    (match Par.Openai_provider.create (Par.Types.Openai { api_key; base_url; organization; embedding_model }) with
     | Ok t ->
       Par.Openai_provider.set_network t net_gen;
       Some { Par.Types.embed_fn = (fun msgs -> Par.Openai_provider.embed t msgs);
              Par.Types.close_fn = (fun () -> Par.Openai_provider.close t) }
     | Error _ -> None)
  | Par.Types.Ollama { base_url } ->
    fd_log (Printf.sprintf "[embed] wiring Ollama (base_url=%s)" base_url);
    (* Ollama doesn't use API keys, but Openai_provider.create validates
       non-empty api_key. Pass a placeholder that Ollama will ignore. *)
    let cfg = Par.Types.Openai { api_key = "ollama-no-auth"; base_url = Some (base_url ^ "/v1"); organization = None; embedding_model = None } in
    (match Par.Openai_provider.create cfg with
     | Ok t ->
       Par.Openai_provider.set_network t net_gen;
       fd_log "[embed] Ollama->Openai compat provider created OK";
       Some { Par.Types.embed_fn = (fun msgs -> Par.Openai_provider.embed t msgs);
              Par.Types.close_fn = (fun () -> Par.Openai_provider.close t) }
     | Error e ->
       let err_str = match e with
         | Par.Types.Timeout -> "Timeout"
         | Par.Types.Invalid_input m -> "Invalid_input: " ^ m
         | _ -> "other"
       in
       fd_log ("[embed] Ollama->Openai create Error: " ^ err_str);
       None)
  | Par.Types.Anthropic _ ->
    fd_log "[embed] Anthropic not supported for embeddings";
    None
  | Par.Types.Custom _ ->
    fd_log "[embed] Custom provider not supported";
    None

(* -------------------------------------------------------------------------- *)
(* do_init: spawns persistent Eio domain, blocks until runtime ready.         *)
(* -------------------------------------------------------------------------- *)

let do_init (config_json : string) =
  fd_log "[do_init] enter";
  let json = Yojson.Safe.from_string config_json in
  let config = match Par.Types.runtime_config_of_yojson json with
    | Ok c -> c
    | Error s -> failwith (Printf.sprintf "Invalid config JSON: %s" s)
  in
  let state_id = alloc_state () in
  let state = Hashtbl.find states state_id in
  fd_log (Printf.sprintf "[do_init] state_id=%d allocated" state_id);
  (* Slot for init result communication *)
  let init_slot : [ `Ok of Par.Runtime.runtime | `Error of string ] result_slot =
    create_slot () in
  let dom = Domain.spawn (fun () ->
    fd_log "[do_init] domain spawned, about to call Eio_main.run";
    Eio_main.run (fun env ->
      fd_log "[do_init] inside Eio_main.run callback";
      (* Initialize the mirage-crypto RNG so TLS works. Required by
         Http_client for HTTPS connections. *)
      Mirage_crypto_rng_unix.use_default ();
      try
        let net = Eio.Stdenv.net env in
        let providers = config.Par.Types.llm_providers in
        fd_log (Printf.sprintf "[do_init] providers=%d" (List.length providers));
        let llm_opt, embed_opt =
          match providers with
          | [] -> (None, None)
          | (_, provider_cfg) :: _ ->
            (build_llm_from_provider provider_cfg net,
             build_embed_from_provider provider_cfg net)
        in
        let llm = Option.value llm_opt ~default:default_llm_service in
        fd_log "[do_init] about to call Runtime.create";
        Eio.Switch.run (fun sw ->
          match Par.Runtime.create ~config ~llm ?embeddings:embed_opt sw with
          | Ok rt ->
            fd_log "[do_init] Runtime.create Ok, putting init slot";
            slot_put init_slot (`Ok rt);
            fd_log "[do_init] entering work_loop";
            work_loop rt env state
          | Error e ->
            let err_str = match e with
              | Par.Types.Timeout -> "Timeout"
              | Par.Types.Invalid_input m -> "Invalid_input: " ^ m
              | Par.Types.External_failure m -> "External_failure: " ^ m
              | Par.Types.Rate_limited -> "Rate_limited"
              | Par.Types.Permission_denied m -> "Permission_denied: " ^ m
              | Par.Types.Internal m -> "Internal: " ^ m
              | Par.Types.Embedding_unsupported -> "Embedding_unsupported"
            in
            fd_log ("[do_init] Runtime.create Error: " ^ err_str);
            slot_put init_slot (`Error err_str)
        )
      with ex ->
        fd_log ("[do_init] EXCEPTION: " ^ Printexc.to_string ex);
        slot_put init_slot (`Error (Printexc.to_string ex))
    )
  ) in
  Hashtbl.replace domains state_id dom;
  fd_log "[do_init] about to take init_slot";
  match slot_take init_slot with
  | `Ok _rt -> fd_log "[do_init] init slot Ok"; Obj.repr state_id
  | `Error msg ->
    fd_log ("[do_init] init slot Error: " ^ msg);
    (match Hashtbl.find_opt domains state_id with
     | Some d -> ignore (Domain.join d)
     | None -> ());
    free_state state_id;
    Hashtbl.remove domains state_id;
    failwith ("Runtime.create failed: " ^ msg)

(* do_shutdown: dispatch Runtime.close to the work loop, then enqueue
   sentinel to terminate the work loop, then join domain. *)
let do_shutdown (state_id : int) =
  match get_state state_id with
  | None -> error_json "Invalid runtime handle"
  | Some state ->
    let result_slot = create_slot () in
    Mutex.lock state.work_mutex;
    Queue.push {
      work = Obj.repr (fun rt _env ->
        let _ = Par.Runtime.close rt in
        Obj.repr 0);
      result = result_slot;
    } state.work_queue;
    (* Sentinel will cause work_loop to exit after processing the close. *)
    Queue.push { work = shutdown_sentinel; result = create_slot () } state.work_queue;
    Condition.signal state.work_cond;
    Condition.signal state.work_cond;
    Mutex.unlock state.work_mutex;
    let _ : Obj.t = slot_take result_slot in
    (match Hashtbl.find_opt domains state_id with
     | Some d -> ignore (Domain.join d)
     | None -> ());
    free_state state_id;
    Hashtbl.remove domains state_id;
    "{\"status\": \"ok\"}"

(* -------------------------------------------------------------------------- *)
(* do_register_tool                                                           *)
(* -------------------------------------------------------------------------- *)

let do_register_tool (state_id : int) (name : string) (desc : string) (schema : string) =
  match get_state state_id with
  | None -> Obj.repr (-1)
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      if String.length name = 0 then Obj.repr (-3)
      else
        (try
           let json_schema = Yojson.Safe.from_string schema in
           (match json_schema with
            | `Assoc _ ->
               (match Par.Runtime.register_tool rt
                  ~name ~description:desc
                  ~input_schema:json_schema
                  ~handler:(fun input _token ->
                    Logs.warn (fun m ->
                      m "FFI tool '%s': no-op handler invoked \
                         (Python callback not yet supported)" name);
                    Par.Types.Success input)
                  () with
                | Ok _ -> Obj.repr 0
                | Error _ -> Obj.repr (-4))
            | _ -> Obj.repr (-2))
         with
          | Yojson.Json_error _ -> Obj.repr (-2)
          | _ -> Obj.repr (-1))) in
    result

external c_invoke_python_handler : int -> string -> string = "caml_invoke_python_handler"

let do_register_tool_with_handler (state_id : int) (name : string) (desc : string)
    (schema : string) (handler_id : int) =
  match get_state state_id with
  | None -> Obj.repr (-1)
  | Some _ ->
    dispatch state_id (fun rt _env ->
      if String.length name = 0 then Obj.repr (-3)
      else
        (try
           let json_schema = Yojson.Safe.from_string schema in
           (match json_schema with
            | `Assoc _ ->
               let handler_fn input _token =
                 let input_str = Yojson.Safe.to_string input in
                 let result_str = c_invoke_python_handler handler_id input_str in
                 let open Par.Types in
                 if String.length result_str = 0 then
                   Error {
                     category = Internal "python handler returned empty";
                     message = Printf.sprintf "Python handler %d returned empty" handler_id;
                     retryable = false;
                     metadata = [];
                   }
                 else
                   (try Success (Yojson.Safe.from_string result_str)
                    with _ ->
                      Error {
                        category = Internal "invalid JSON from Python handler";
                        message = "Python handler returned invalid JSON";
                        retryable = false;
                        metadata = [];
                      })
               in
               (match Par.Runtime.register_tool rt
                  ~name ~description:desc
                  ~input_schema:json_schema
                  ~handler:handler_fn
                  () with
                 | Ok _ -> Obj.repr 0
                 | Error _ -> Obj.repr (-4))
            | _ -> Obj.repr (-2))
         with
         | Yojson.Json_error _ -> Obj.repr (-2)
         | _ -> Obj.repr (-1)))

(* -------------------------------------------------------------------------- *)
(* Config parsers (unchanged from previous code)                              *)
(* -------------------------------------------------------------------------- *)

let parse_provider (s : string) : [> `Openai | `Anthropic | `Ollama | `Custom of string ] =
  match String.lowercase_ascii s with
  | "openai" -> `Openai
  | "anthropic" -> `Anthropic
  | "ollama" -> `Ollama
  | s -> `Custom s

let parse_model_config (json : Yojson.Safe.t) : Par.Types.model_config =
  let open Yojson.Safe.Util in
  let provider_str = json |> member "provider" |> to_string_option |> Option.value ~default:"openai" in
  let provider = parse_provider provider_str in
  let model_name = json |> member "model_name" |> to_string in
  let api_base = json |> member "api_base" |> to_string_option in
  let temperature = json |> member "temperature" |> to_float_option |> Option.value ~default:0.7 in
  let max_tokens = json |> member "max_tokens" |> to_int_option in
  let top_p = json |> member "top_p" |> to_float_option in
  let stop_sequences =
    match json |> member "stop_sequences" with
    | `Null -> []
    | `List _ as v -> Yojson.Safe.Util.to_list v |> List.filter_map Yojson.Safe.Util.to_string_option
    | _ -> []
  in
  { provider; model_name; api_base; temperature; max_tokens; top_p; stop_sequences = Some stop_sequences }

let parse_system_prompt_template (json : Yojson.Safe.t) : Par.Types.system_prompt_template =
  let open Yojson.Safe.Util in
  let template = json |> member "template" |> to_string in
  let variables = json |> member "variables" |> to_list |> List.filter_map to_string_option in
  let required = json |> member "required" |> to_list |> List.filter_map to_string_option in
  { template; variables; required }

let parse_tool_descriptor (json : Yojson.Safe.t) : Par.Types.tool_descriptor =
  let open Yojson.Safe.Util in
  let name = json |> member "name" |> to_string in
  let description = json |> member "description" |> to_string in
  let input_schema = json |> member "input_schema" in
  let permission = Par.Types.Allow in
  let timeout = json |> member "timeout" |> to_float_option in
  let concurrency_limit = json |> member "concurrency_limit" |> to_int_option in
  { name; description; input_schema; output_schema = None; permission; timeout; concurrency_limit; on_update = None }

let parse_resource_quota (json : Yojson.Safe.t) : Par.Types.resource_quota =
  let open Yojson.Safe.Util in
  let max_concurrent_tasks = json |> member "max_concurrent_tasks" |> to_int_option |> Option.value ~default:max_int in
  let max_concurrent_tools_per_agent = json |> member "max_concurrent_tools_per_agent" |> to_int_option |> Option.value ~default:max_int in
  let max_tokens_per_turn = json |> member "max_tokens_per_turn" |> to_int_option in
  let max_total_tokens = json |> member "max_total_tokens" |> to_int_option in
  { max_concurrent_tasks; max_concurrent_tools_per_agent; max_tokens_per_turn; max_total_tokens }

let parse_agent_config (json : Yojson.Safe.t) : Par.Types.agent_config =
  let open Yojson.Safe.Util in
  let id = json |> member "id" |> to_string in
  let system_prompt = json |> member "system_prompt" |> to_string in
  let system_prompt_template = match json |> member "system_prompt_template" with
    | `Assoc _ as v -> Some (parse_system_prompt_template v)
    | _ -> None
  in
  let model = json |> member "model" |> parse_model_config in
  let tools = json |> member "tools" |> to_list |> List.map parse_tool_descriptor in
  let max_iterations = json |> member "max_iterations" |> to_int_option |> Option.value ~default:10 in
  let middleware = [] in
  let retry_policy = None in
  let context_strategy = None in
  let resource_quota = match json |> member "resource_quota" with
    | `Assoc _ as v -> Some (parse_resource_quota v)
    | _ -> None
  in
  { id; system_prompt; system_prompt_template; model; tools; max_iterations;
    middleware; retry_policy; context_strategy; resource_quota }

let do_register_agent (state_id : int) (config_json : string) =
  match get_state state_id with
  | None -> Obj.repr (-1)
  | Some _ ->
    dispatch state_id (fun rt _env ->
      (try
         let json = Yojson.Safe.from_string config_json in
         let config = parse_agent_config json in
         match Par.Runtime.register_agent rt config with
         | Ok () -> Obj.repr 0
         | Error _ -> Obj.repr (-1)
       with
       | exc ->
         fd_log ("[do_register_agent] EXCEPTION: " ^ Printexc.to_string exc);
         Obj.repr (-1)))

let do_invoke (state_id : int) (agent_id : string) (message : string) =
  match get_state state_id with
  | None -> None
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      (try
         let result = Par.Runtime.invoke rt
           ~agent_id ~message () in
         let json = match result with
           | Ok { Par.Types.response = resp; conversation = _ } ->
             Printf.sprintf "{\"status\": \"ok\", \"content\": %s}"
               (Yojson.Safe.to_string (Par.Types.llm_response_to_yojson resp))
           | Error (err, _) ->
             error_json (Printf.sprintf "Invoke failed: %s"
               (Yojson.Safe.to_string (Par.Types.error_category_to_yojson err)))
         in
         Obj.repr (Some json)
       with e -> Obj.repr (Some (error_json (Printexc.to_string e))))) in
    (Obj.obj result : string option)

let do_invoke_structured (state_id : int) (agent_id : string) (message : string) (schema_json : string) =
  match get_state state_id with
  | None -> None
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      (try
         let response_schema = Yojson.Safe.from_string schema_json in
         let result = Par.Runtime.invoke_structured rt
           ~agent_id ~message ~response_schema () in
         let json = match result with
           | Ok { Par.Types.value; raw_response; conversation = _; attempts } ->
             Printf.sprintf
               "{\"status\": \"ok\", \"value\": %s, \"raw\": %s, \"attempts\": %d}"
               (Yojson.Safe.to_string value)
               (Yojson.Safe.to_string (Par.Types.llm_response_to_yojson raw_response))
               attempts
           | Error (err, _) ->
             error_json (Printf.sprintf "Invoke_structured failed: %s"
               (Yojson.Safe.to_string (Par.Types.error_category_to_yojson err)))
         in
         Obj.repr (Some json)
       with e -> Obj.repr (Some (error_json (Printexc.to_string e))))) in
    (Obj.obj result : string option)

let do_invoke_stream (state_id : int) (agent_id : string) (message : string) =
  match get_state state_id with
  | None -> error_json "Invalid runtime handle"
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      (try
         let chunk_buf = ref [] in
         let on_chunk chunk =
           let json =
             Par.Types.llm_response_chunk_to_yojson chunk
             |> Yojson.Safe.to_string
           in
           chunk_buf := json :: !chunk_buf
         in
         let result = Par.Runtime.invoke rt
           ~agent_id ~message
           ~on_chunk:(Some on_chunk)
           () in
         let chunks_json =
           `List (List.rev_map (fun s -> `Assoc [("chunk", Yojson.Safe.from_string s)]) !chunk_buf)
           |> Yojson.Safe.to_string
         in
         let json = match result with
           | Ok { Par.Types.response = resp; conversation = _ } ->
             Printf.sprintf "{\"status\": \"ok\", \"content\": %s, \"chunks\": %s}"
               (Yojson.Safe.to_string (Par.Types.llm_response_to_yojson resp))
               chunks_json
           | Error (err, _) ->
             error_json (Printf.sprintf "Invoke_stream failed: %s"
               (Yojson.Safe.to_string (Par.Types.error_category_to_yojson err)))
         in
         Obj.repr json
       with e -> Obj.repr (error_json (Printexc.to_string e)))) in
    (Obj.obj result : string)

let parse_workflow (json : Yojson.Safe.t) : Par.Types.workflow =
  let open Yojson.Safe.Util in
  let id = json |> member "id" |> to_string in
  let name = json |> member "name" |> to_string in
  let version = json |> member "version" |> to_int_option |> Option.value ~default:1 in
  let steps_json = json |> member "steps" in
  let steps = match Par.Types.workflow_step_of_yojson steps_json with
    | Ok s -> s
    | Error _ -> Par.Types.Sequential []
  in
  let variables_json = json |> member "variables" |> to_assoc |> List.map (fun (k, v) -> (k, v)) in
  let failure_policy = Par.Types.Fail_fast in
  let parallel_limit = json |> member "parallel_limit" |> to_int_option |> Option.value ~default:4 in
  let timeout = json |> member "timeout" |> to_float_option |> Option.value ~default:3600.0 in
  let on_complete = None in
  { id; name; version; steps; variables = variables_json;
    failure_policy; parallel_limit; timeout; on_complete }

let do_submit_workflow (state_id : int) (workflow_json : string) =
  match get_state state_id with
  | None -> None
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      (try
         let json = Yojson.Safe.from_string workflow_json in
         let wf = parse_workflow json in
         match Par.Runtime.submit_workflow rt wf with
         | Ok run_id ->
           let json_response = Printf.sprintf "{\"status\": \"ok\", \"workflow_run_id\": \"%s\"}"
             (Par.Types.Workflow_run_id.to_string run_id)
           in
           Obj.repr (Some json_response)
         | Error err ->
           Obj.repr (Some (error_json (Printf.sprintf "submit_workflow failed: %s"
             (Yojson.Safe.to_string (Par.Types.error_category_to_yojson err)))))
       with e -> Obj.repr (Some (error_json (Printexc.to_string e))))) in
    (Obj.obj result : string option)

let do_approve_workflow (state_id : int) (run_id : string) (approver : string) =
  match get_state state_id with
  | None -> -1
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      (try
         let wf_id = Par.Types.Workflow_run_id.of_string run_id in
         let result = Par.Runtime.approve_workflow rt wf_id ~approver in
         (match result with
          | Ok () -> Obj.repr 0
          | Error _ -> Obj.repr (-1))
       with _ -> Obj.repr (-1))) in
    (Obj.obj result : int)

let do_resume_workflow (state_id : int) (run_id : string) =
  match get_state state_id with
  | None -> None
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      (try
         let wf_id = Par.Types.Workflow_run_id.of_string run_id in
         let result = Par.Runtime.resume_workflow rt wf_id in
         let json = match result with
           | Ok (Some wf_result) ->
             Printf.sprintf "{\"status\": \"ok\", \"result\": %s}"
               (Yojson.Safe.to_string (Par.Types.workflow_result_to_yojson wf_result))
           | Ok None -> "{\"status\": \"ok\", \"result\": null}"
           | Error err ->
             error_json (Printf.sprintf "resume_workflow failed: %s"
               (Yojson.Safe.to_string (Par.Types.error_category_to_yojson err)))
         in
         Obj.repr (Some json)
       with e -> Obj.repr (Some (error_json (Printexc.to_string e))))) in
    (Obj.obj result : string option)

let do_mcp_server (state_id : int) (sid : string) : string option =
  match get_state state_id with
  | None -> Some (error_json "Invalid runtime handle")
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      (try
         match Par.Mcp_types.server_id_of_string sid with
         | Error e -> Obj.repr (Some (error_json (Yojson.Safe.to_string (Par.Types.error_category_to_yojson e))))
         | Ok server_id ->
           (match Par.Runtime.mcp_server rt server_id with
            | Error e -> Obj.repr (Some (error_json (Yojson.Safe.to_string (Par.Types.error_category_to_yojson e))))
            | Ok _server ->
              Obj.repr (Some "{\"status\": \"ok\", \"note\": \"mcp_server connected\"}"))
       with e ->
         Obj.repr (Some (error_json (Printexc.to_string e))))) in
    (Obj.obj result : string option)

let do_mcp_list_tools (state_id : int) (sid : string) : string option =
  match get_state state_id with
  | None -> Some (error_json "Invalid runtime handle")
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      (try
         match Par.Mcp_types.server_id_of_string sid with
         | Error e -> Obj.repr (Some (error_json (Yojson.Safe.to_string (Par.Types.error_category_to_yojson e))))
         | Ok server_id ->
           (match Par.Runtime.mcp_server rt server_id with
            | Error e -> Obj.repr (Some (error_json (Yojson.Safe.to_string (Par.Types.error_category_to_yojson e))))
            | Ok server ->
              let tools = Par.Mcp_client.list_tools (Par.Mcp_client.of_server server) in
              (match tools with
               | Error e -> Obj.repr (Some (error_json (Yojson.Safe.to_string (Par.Types.error_category_to_yojson e))))
               | Ok tl ->
                 let arr = List.map (fun (t : Par.Mcp_types.mcp_tool) ->
                   Printf.sprintf "{\"name\":\"%s\"}" (json_escape t.Par.Mcp_types.name)
                 ) tl in
                 Obj.repr (Some (Printf.sprintf "{\"tools\":[%s]}" (String.concat "," arr)))))
       with e ->
         Obj.repr (Some (error_json (Printexc.to_string e))))) in
    (Obj.obj result : string option)

let do_workflow_status (state_id : int) (run_id : string) : string option =
  match get_state state_id with
  | None -> Some (error_json "Invalid runtime handle")
  | Some _ ->
    Obj.obj (Obj.repr (Some (Printf.sprintf "{\"run_id\":\"%s\",\"status\":\"unknown\"}" (json_escape run_id))))

let do_workflow_cancel (state_id : int) (_run_id : string) : int =
  match get_state state_id with
  | None -> -1
  | Some _ -> -1

let do_event_subscribe (_state_id : int) (_cb : int) : int =
  incr state_counter;
  !state_counter

let do_version () : string = Par.Version.version

let do_health (state_id : int) : string =
  match get_state state_id with
  | None -> error_json "Invalid runtime handle"
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      let h = Par.Runtime.health rt in
      let json = Printf.sprintf
        "{\"status\": \"ok\", \"runtime_alive\": %s, \"persistence_ok\": %s, \
         \"last_llm_call_at\": %s, \"last_llm_call_status\": \"%s\"}"
        (if h.runtime_alive then "true" else "false")
        (if h.persistence_ok then "true" else "false")
        (match h.last_llm_call_at with Some f -> Printf.sprintf "%f" f | None -> "null")
        (match h.last_llm_call_status with
         | `Success -> "Success" | `Never_called -> "Never_called"
         | `Error (Types.Internal _) -> "Error.Internal"
         | `Error (Types.Timeout) -> "Error.Timeout"
         | `Error (Types.Invalid_input _) -> "Error.Invalid_input"
         | `Error (Types.External_failure _) -> "Error.External_failure"
         | `Error (Types.Rate_limited) -> "Error.Rate_limited"
         | `Error (Types.Permission_denied _) -> "Error.Permission_denied"
         | `Error (Types.Embedding_unsupported) -> "Error.Embedding_unsupported")
      in
      Obj.repr json) in
    (Obj.obj result : string)

let do_metrics (state_id : int) : string =
  match get_state state_id with
  | None -> error_json "Invalid runtime handle"
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      let snap = Par.Runtime.metrics_snapshot rt in
      let pairs = List.map (fun (k, v) ->
        Printf.sprintf "\"%s\": %d" k v
      ) snap in
      let json = Printf.sprintf "{\"status\": \"ok\", \"metrics\": {%s}}"
        (String.concat ", " pairs) in
      Obj.repr json) in
    (Obj.obj result : string)

let do_steer (state_id : int) (message : string) : int =
  match get_state state_id with
  | None -> -1
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      Par.Runtime.steer rt message;
      Obj.repr 0) in
    (Obj.obj result : int)

let do_follow_up (state_id : int) (message : string) : int =
  match get_state state_id with
  | None -> -1
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      Par.Runtime.follow_up rt message;
      Obj.repr 0) in
    (Obj.obj result : int)

(* -------------------------------------------------------------------------- *)
(* Vector store lifecycle (lazy per-runtime)                                  *)
(* -------------------------------------------------------------------------- *)

let vec_extension_path =
  if Sys.os_type = "Unix"
  then "vendor/sqlite-vec/linux-x86_64/vec0.so"
  else "vendor/sqlite-vec/macos-aarch64/vec0.dylib"

let runtime_vector_stores : (int, Par.Vector_store.t) Hashtbl.t = Hashtbl.create 8

let ensure_vector_store state_id dim =
  match Hashtbl.find_opt runtime_vector_stores state_id with
  | Some vs -> vs
  | None ->
    (match Par.Vector_store.create
       ~db_path:":memory:"
       ~vec_extension_path
       ~dimension:dim () with
     | Ok vs -> Hashtbl.add runtime_vector_stores state_id vs; vs
     | Error e -> failwith (Types.error_category_to_yojson e |> Yojson.Safe.to_string))

(* -------------------------------------------------------------------------- *)
(* RAG operations: dispatch through work loop                                  *)
(* -------------------------------------------------------------------------- *)

let do_embed (state_id : int) (messages_json : string) : string =
  match get_state state_id with
  | None -> "{\"error\":\"runtime handle not found\"}"
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      (try
         let messages =
           match Yojson.Safe.from_string messages_json with
           | `List xs -> List.map (function `String s -> s | _ -> "") xs
           | `String s -> [s]
           | _ -> []
         in
         (match Runtime.embed rt messages with
          | Ok vecs ->
            let vec_to_json vec =
              `List (Array.to_list (Array.map (fun f -> `Float f) vec))
            in
            Obj.repr (Yojson.Safe.to_string (`List (List.map vec_to_json vecs)))
          | Error err ->
            let err_str = match err with
              | Par.Types.Timeout -> "Timeout"
              | Par.Types.Invalid_input m -> "Invalid_input: " ^ m
              | Par.Types.External_failure m -> "External_failure: " ^ m
              | Par.Types.Rate_limited -> "Rate_limited"
              | Par.Types.Permission_denied m -> "Permission_denied: " ^ m
              | Par.Types.Internal m -> "Internal: " ^ json_escape m
              | Par.Types.Embedding_unsupported -> "Embedding_unsupported"
            in
            Obj.repr (Printf.sprintf "{\"error\":\"embed failed: %s\"}" err_str))
       with exc ->
         Obj.repr (Printf.sprintf "{\"error\":\"exception: %s\"}" (Printexc.to_string exc)))) in
    (Obj.obj result : string)

let do_add_documents (state_id : int) (docs_json : string) : int =
  match get_state state_id with
  | None -> -1
  | Some _ ->
    let result = dispatch state_id (fun rt _env ->
      (try
         let docs =
           match Yojson.Safe.from_string docs_json with
           | `List xs ->
             List.map (fun item ->
               match item with
               | `Assoc fields ->
                 let id = match List.assoc_opt "id" fields with Some (`String s) -> s | _ -> Printf.sprintf "doc_%d" (Random.int 1000000) in
                 let content = match List.assoc_opt "content" fields with Some (`String s) -> s | _ -> "" in
                 let metadata = List.assoc_opt "metadata" fields in
                 { Par.Vector_store.id; content; metadata }
               | `String s -> { Par.Vector_store.id = Printf.sprintf "doc_%d" (Random.int 1000000); content = s; metadata = None }
               | _ -> { Par.Vector_store.id = Printf.sprintf "doc_%d" (Random.int 1000000); content = Yojson.Safe.to_string item; metadata = None }
             ) xs
           | _ -> []
         in
         if docs = [] then Obj.repr 0
         else
           (match Runtime.embed rt (List.map (fun d -> d.Vector_store.content) docs) with
            | Error _ -> Obj.repr (-2)
            | Ok [] -> Obj.repr (-3)
            | Ok (first_vec :: _ as vecs) ->
              let dim = Array.length first_vec in
              let vs = ensure_vector_store state_id dim in
              let doc_vecs = List.mapi (fun i vec ->
                (List.nth docs i, vec)) vecs in
              (match Par.Vector_store.add vs doc_vecs with
               | Ok () -> Obj.repr 0
               | Error _ -> Obj.repr (-4)))
       with _ -> Obj.repr (-5))) in
    (Obj.obj result : int)

let do_invoke_with_rag (state_id : int) (agent_id : string) (message : string) (k_str : string) : string =
  match get_state state_id with
  | None -> "{\"error\":\"runtime handle not found\"}"
  | Some _ ->
    let k = try int_of_string k_str with _ -> 4 in
    let vs = Hashtbl.find_opt runtime_vector_stores state_id in
    let result = dispatch state_id (fun rt _env ->
      (try
         (match Runtime.invoke_with_rag rt
            ~agent_id ~message ~k ?vector_store:vs () with
          | Ok (result, _docs) ->
            Obj.repr (Types.llm_response_to_yojson result.Types.response |> Yojson.Safe.to_string)
          | Error e ->
            Obj.repr (Printf.sprintf "{\"error\":\"%s\"}" (Types.error_category_to_yojson e |> Yojson.Safe.to_string)))
       with exc ->
         Obj.repr (Printf.sprintf "{\"error\":\"exception: %s\"}" (Printexc.to_string exc)))) in
    (Obj.obj result : string)

(* -------------------------------------------------------------------------- *)
(* Callback registrations                                                     *)
(* -------------------------------------------------------------------------- *)

let unwrap : string option -> Obj.t = function
  | Some v -> Obj.repr v
  | None -> Obj.repr "{\"error\": \"internal: no response from worker\"}"

let () =
  Callback.register "par_init" (fun (config_json : string) ->
    do_init config_json)

let () =
  Callback.register "par_shutdown" (fun (state_id_obj : Obj.t) ->
    let state_id : int = Obj.magic state_id_obj in
    do_shutdown state_id)

let () =
  Callback.register "par_register_tool"
    (fun (state_id_obj : Obj.t) (name : string) (desc : string) (schema : string) ->
      let state_id : int = Obj.magic state_id_obj in
      do_register_tool state_id name desc schema)

let () =
  Callback.register "par_register_tool_with_handler"
    (fun (state_id_obj : Obj.t) (name : string) (desc : string) (schema : string) (handler_id : int) ->
      let state_id : int = Obj.magic state_id_obj in
      do_register_tool_with_handler state_id name desc schema handler_id)

let () =
  Callback.register "par_register_agent"
    (fun (state_id_obj : Obj.t) (config_json : string) ->
      let state_id : int = Obj.magic state_id_obj in
      do_register_agent state_id config_json)

let () =
  Callback.register "par_invoke"
    (fun (state_id_obj : Obj.t) (agent_id : string) (message : string) ->
      let state_id : int = Obj.magic state_id_obj in
      unwrap (do_invoke state_id agent_id message))

let () =
  Callback.register "par_embed"
    (fun (state_id_obj : Obj.t) (messages_json : string) ->
      let state_id : int = Obj.magic state_id_obj in
      do_embed state_id messages_json)

let () =
  Callback.register "par_invoke_structured"
    (fun (state_id_obj : Obj.t) (agent_id : string) (message : string) (schema_json : string) ->
      let state_id : int = Obj.magic state_id_obj in
      unwrap (do_invoke_structured state_id agent_id message schema_json))

let () =
  Callback.register "par_invoke_stream"
    (fun (state_id_obj : Obj.t) (agent_id : string) (message : string) ->
      let state_id : int = Obj.magic state_id_obj in
      do_invoke_stream state_id agent_id message)

let () =
  Callback.register "par_submit_workflow"
    (fun (state_id_obj : Obj.t) (workflow_json : string) ->
      let state_id : int = Obj.magic state_id_obj in
      unwrap (do_submit_workflow state_id workflow_json))

let () =
  Callback.register "par_approve_workflow"
    (fun (state_id_obj : Obj.t) (run_id : string) (approver : string) ->
      let state_id : int = Obj.magic state_id_obj in
      do_approve_workflow state_id run_id approver)

let () =
  Callback.register "par_resume_workflow"
    (fun (state_id_obj : Obj.t) (run_id : string) ->
      let state_id : int = Obj.magic state_id_obj in
      unwrap (do_resume_workflow state_id run_id))

let () =
  Callback.register "par_health"
    (fun (state_id_obj : Obj.t) ->
      let state_id : int = Obj.magic state_id_obj in
      do_health state_id)

let () =
  Callback.register "par_metrics"
    (fun (state_id_obj : Obj.t) ->
      let state_id : int = Obj.magic state_id_obj in
      do_metrics state_id)

let () =
  Callback.register "par_steer"
    (fun (state_id_obj : Obj.t) (message : string) ->
      let state_id : int = Obj.magic state_id_obj in
      do_steer state_id message)

let () =
  Callback.register "par_follow_up"
    (fun (state_id_obj : Obj.t) (message : string) ->
      let state_id : int = Obj.magic state_id_obj in
      do_follow_up state_id message)

let () =
  Callback.register "par_mcp_server"
    (fun (state_id_obj : Obj.t) (server_id : string) ->
      let state_id : int = Obj.magic state_id_obj in
      unwrap (do_mcp_server state_id server_id))

let () =
  Callback.register "par_mcp_list_tools"
    (fun (state_id_obj : Obj.t) (server_id : string) ->
      let state_id : int = Obj.magic state_id_obj in
      unwrap (do_mcp_list_tools state_id server_id))

let () =
  Callback.register "par_workflow_status"
    (fun (state_id_obj : Obj.t) (run_id : string) ->
      let state_id : int = Obj.magic state_id_obj in
      unwrap (do_workflow_status state_id run_id))

let () =
  Callback.register "par_workflow_cancel"
    (fun (state_id_obj : Obj.t) (run_id : string) ->
      let state_id : int = Obj.magic state_id_obj in
      do_workflow_cancel state_id run_id)

let () =
  Callback.register "par_event_subscribe"
    (fun (state_id_obj : Obj.t) (cb_val : Obj.t) ->
      let state_id : int = Obj.magic state_id_obj in
      let cb = Obj.magic cb_val in
      do_event_subscribe state_id cb)

let () =
  Callback.register "par_version"
    (fun (_unit : Obj.t) ->
      Obj.repr (do_version ()))

let () =
  Callback.register "par_add_documents"
    (fun (state_id_obj : Obj.t) (docs_json : string) ->
      let state_id : int = Obj.magic state_id_obj in
      Obj.repr (do_add_documents state_id docs_json))

let () =
  Callback.register "par_invoke_with_rag"
    (fun (state_id_obj : Obj.t) (agent_id : string) (message : string) (k_str : string) ->
      let state_id : int = Obj.magic state_id_obj in
      do_invoke_with_rag state_id agent_id message k_str)
