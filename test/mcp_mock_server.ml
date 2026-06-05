(* test/mcp_mock_server.ml — minimal MCP test fixture (v0.3.1 W2)
   Speaks JSON-RPC 2.0 over stdin/stdout per MCP spec 2025-06-18.
   Used as a test fixture for lib/mcp/mcp_transport_stdio, mcp_server, mcp_client, Runtime.

   Supported methods (per MCP spec 2025-06-18):
     initialize              — handshake (skipped if --no-initialize-response)
     notifications/initialized — silently accepted
     tools/list              — 4 tools: echo / add / slow / crash
     tools/call              — see per-tool below
     resources/list          — 2 resources
     resources/read          — mock://hello (text) / mock://data (base64)
     prompts/list            — 1 prompt: greeting
     prompts/get             — renders with arguments.name
     shutdown                — respond + exit 0
     notifications/cancelled — silently dropped
     * other methods         — -32601 Method not found

   CLI flags:
     --crash-on-startup       exit 1 before reading any line
     --no-initialize-response read initialize, never reply (test timeout)
     --garbage-on-stderr      spam stderr every 50ms (test stderr drain)
     --slow-tools-list        sleep 5s on tools/list (test request timeout)

   NOTE: Adapted from spec to compile against eio 1.3 / eio_main 1.3:
     - jsonrpc_response / jsonrpc_error carry explicit Yojson.Safe.t annotations
       (otherwise OCaml's value-restriction / polymorphic variant inference
        unifies [id] and [result] into a single variant that won't accept
        an [Assoc] payload).
     - Call sites wrap the second arg in parens: [~id (`Assoc [...])].
       Without parens, OCaml parses the polymorphic-variant tag as a
       separate partial application and complains "applied to too many arguments".
     - Eio.Buf_write.write_string doesn't exist; we use Eio.Flow.copy_string
       directly to env#stdout (Eio.Flow has no flush; each call is a single write).
     - Eio.Buf_read.line returns string and raises End_of_file; we wrap in
       try/with to model the spec's option-style API.
     - Eio.Stdenv.clock is a function (needs env); garbage_fiber now takes
       the clock as an argument, like the rest of the loop.
*)

let _executable_name = "mcp_mock_server"

(* ---------- CLI flag parsing ---------- *)

let parse_flags () =
  let crash = ref false in
  let no_init = ref false in
  let garbage = ref false in
  let slow = ref false in
  Array.iter (fun arg ->
    match arg with
    | "--crash-on-startup" -> crash := true
    | "--no-initialize-response" -> no_init := true
    | "--garbage-on-stderr" -> garbage := true
    | "--slow-tools-list" -> slow := true
    | _ -> ()
  ) Sys.argv;
  !crash, !no_init, !garbage, !slow

(* ---------- JSON helpers ---------- *)

let jsonrpc_response ~id (result : Yojson.Safe.t) : Yojson.Safe.t =
  `Assoc [
    "jsonrpc", `String "2.0";
    "id", id;
    "result", result;
  ]

let jsonrpc_error ~id ~code ~message : Yojson.Safe.t =
  `Assoc [
    "jsonrpc", `String "2.0";
    "id", id;
    "error", `Assoc [
      "code", `Int code;
      "message", `String message;
    ];
  ]

let text_content s =
  `List [`Assoc ["type", `String "text"; "text", `String s]]

let is_error_content s =
  `Assoc ["content", text_content s; "isError", `Bool true]

let ok_content s =
  `Assoc ["content", text_content s; "isError", `Bool false]

(* ---------- Method dispatch ---------- *)

let handle ~slow_tools_list (json : Yojson.Safe.t) : Yojson.Safe.t option =
  let open Yojson.Safe.Util in
  let id = json |> member "id" in
         let method_ = json |> member "method" |> to_string_option in
  match method_ with
  | Some "initialize" ->
      Some (jsonrpc_response ~id (`Assoc [
        "protocolVersion", `String "2025-06-18";
        "capabilities", `Assoc [
          "tools", `Assoc [];
          "resources", `Assoc [];
          "prompts", `Assoc [];
        ];
        "serverInfo", `Assoc [
          "name", `String "par-mock";
          "version", `String "0.1.0";
        ];
      ]))
  | Some "tools/list" ->
      if slow_tools_list then None
      else Some (jsonrpc_response ~id (`Assoc [
        "tools", `List [
          `Assoc ["name", `String "echo"; "description", `String "Echoes input"; "inputSchema", `Assoc ["type", `String "object"]];
          `Assoc ["name", `String "add"; "description", `String "Adds two ints"; "inputSchema", `Assoc ["type", `String "object"]];
          `Assoc ["name", `String "slow"; "description", `String "Sleeps then returns"; "inputSchema", `Assoc ["type", `String "object"]];
          `Assoc ["name", `String "crash"; "description", `String "Returns isError"; "inputSchema", `Assoc ["type", `String "object"]];
        ];
      ]))
  | Some "tools/call" ->
      let name = json |> member "params" |> member "name" |> to_string_option in
      (match name with
       | Some "echo" ->
           let msg = json |> member "params" |> member "arguments" |> member "message" |> to_string_option |> Option.value ~default:"" in
           Some (jsonrpc_response ~id (ok_content msg))
       | Some "add" ->
           let a = json |> member "params" |> member "arguments" |> member "a" |> to_int_option |> Option.value ~default:0 in
           let b = json |> member "params" |> member "arguments" |> member "b" |> to_int_option |> Option.value ~default:0 in
           Some (jsonrpc_response ~id (ok_content (string_of_int (a + b))))
       | Some "slow" ->
           let _delay_ms = json |> member "params" |> member "arguments" |> member "delay_ms" |> to_float_option |> Option.value ~default:100.0 in
           Some (jsonrpc_response ~id (ok_content "slow done"))
           (* Note: actual sleep is done by caller (handle_request) because we need Eio clock *)
       | Some "crash" ->
           Some (jsonrpc_response ~id (is_error_content "crashed"))
       | _ ->
           Some (jsonrpc_error ~id ~code:(-32601) ~message:"Method not found"))
  | Some "resources/list" ->
      Some (jsonrpc_response ~id (`Assoc [
        "resources", `List [
          `Assoc ["uri", `String "mock://hello"; "name", `String "Hello"; "mimeType", `String "text/plain"];
          `Assoc ["uri", `String "mock://data"; "name", `String "Data"; "mimeType", `String "application/octet-stream"];
        ];
      ]))
  | Some "resources/read" ->
      let uri = json |> member "params" |> member "uri" |> to_string_option |> Option.value ~default:"" in
      (match uri with
       | "mock://hello" ->
           Some (jsonrpc_response ~id (`Assoc [
             "contents", `List [
               `Assoc ["uri", `String "mock://hello"; "mimeType", `String "text/plain"; "text", `String "Hello, MCP!"];
             ];
           ]))
       | "mock://data" ->
           Some (jsonrpc_response ~id (`Assoc [
             "contents", `List [
               `Assoc ["uri", `String "mock://data"; "mimeType", `String "application/octet-stream"; "blob", `String "AAEC"];
             ];
           ]))
       | _ ->
           Some (jsonrpc_error ~id ~code:(-32002) ~message:"Resource not found"))
  | Some "prompts/list" ->
      Some (jsonrpc_response ~id (`Assoc [
        "prompts", `List [
          `Assoc [
            "name", `String "greeting";
            "description", `String "Greets a person";
            "arguments", `List [
              `Assoc ["name", `String "name"; "description", `String "Person to greet"; "required", `Bool true];
            ];
          ];
        ];
      ]))
  | Some "prompts/get" ->
      let n = json |> member "params" |> member "arguments" |> member "name" |> to_string_option |> Option.value ~default:"World" in
      Some (jsonrpc_response ~id (`Assoc [
        "description", `String "A friendly greeting";
        "messages", `List [
          `Assoc ["role", `String "user"; "content", `Assoc ["type", `String "text"; "text", `String (Printf.sprintf "Hello, %s!" n)]];
        ];
      ]))
  | Some "ping" ->
      Some (jsonrpc_response ~id (`Assoc []))
  | Some "shutdown" ->
      Some (jsonrpc_response ~id (`Assoc []))
  | Some "notifications/initialized" | Some "notifications/cancelled" ->
      None  (* No response for notifications *)
  | _ ->
      Some (jsonrpc_error ~id ~code:(-32601) ~message:"Method not found")

(* ---------- Main loop ---------- *)

let write_line out s =
  Eio.Flow.copy_string s out;
  Eio.Flow.copy_string "\n" out

let read_line_opt in_ =
  try Some (Eio.Buf_read.line in_)
  with End_of_file -> None

let rec handle_request env in_ out clock slow_tools_list no_init_response =
  match read_line_opt in_ with
  | None -> ()
  | Some raw ->
      (try
         let json = Yojson.Safe.from_string raw in
         let open Yojson.Safe.Util in
  let method_ = json |> member "method" |> to_string_option in
         (* Slow tool: sleep before responding *)
         (match method_ with
          | Some "tools/call" ->
              (match json |> member "params" |> member "name" |> to_string_option with
               | Some "slow" ->
                   let delay_ms = json |> member "params" |> member "arguments" |> member "delay_ms" |> to_float_option |> Option.value ~default:100.0 in
                   Eio.Time.sleep clock (delay_ms /. 1000.0)
               | _ -> ())
          | _ -> ());
         (* Skip initialize response if --no-initialize-response *)
         let skip = (no_init_response && method_ = Some "initialize") in
         if not skip then begin
           match handle ~slow_tools_list json with
           | Some resp -> write_line out (Yojson.Safe.to_string resp)
           | None -> ()
         end;
         (* Stop after shutdown *)
         if method_ = Some "shutdown" then ()
         else handle_request env in_ out clock slow_tools_list no_init_response
       with Yojson.Json_error _ ->
         handle_request env in_ out clock slow_tools_list no_init_response)

let garbage_fiber clock stderr =
  let i = ref 0 in
  let rec loop () =
    Eio.Time.sleep clock 0.05;
    Eio.Flow.copy_string (Printf.sprintf "[garbage] line %d\n" !i) stderr;
    incr i;
    loop ()
  in
  loop ()

let () =
  let crash, no_init_response, garbage, slow_tools_list = parse_flags () in
  if crash then begin
    prerr_endline "mock: crashing on startup";
    exit 1
  end;
  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
      if garbage then
        Eio.Fiber.fork ~sw (fun () -> garbage_fiber env#clock env#stderr);
      (* Treat stdin as a Buf_read; stdout as a sink. *)
      let in_ = Eio.Buf_read.of_flow env#stdin ~max_size:1_048_576 in
      let out = env#stdout in
      handle_request env in_ out env#clock slow_tools_list no_init_response
