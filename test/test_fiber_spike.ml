(* SPIKE GATE (Step 0) — Prove Eio.Fiber.with_binding propagates into
   Engine.run_agent's parallel tool fork (engine.ml:864-869).

   This is the critical experiment that gates the hybrid invoke_context
   architecture. If Fiber.with_binding does NOT propagate into fork_promise,
   the entire "Engine reads per-call state via Fiber.get" design collapses and
   we must fall back to threading ?invoke_context through Engine.run_agent.

   Setup mirrors Engine's parallel tool dispatch exactly:
     - parent fiber binds a key
     - forks a child via Eio.Fiber.fork_promise (same primitive engine.ml:866)
     - child reads the key
     - parent awaits the child's promise

   PASS  = propagation works -> proceed to Step 1 (hybrid model).
   FAIL  = STOP IMMEDIATELY, report, fall back to explicit param threading. *)

let test_key : string Eio.Fiber.key = Eio.Fiber.create_key ()

let () =
  print_endline "[spike] starting fiber-binding propagation test";
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      (* Parent binds the key — this is what invoke entry will do. *)
      let result =
        Eio.Fiber.with_binding test_key "hello-from-parent" (fun () ->
          (* Fork a child fiber exactly like Engine.run_agent's parallel
             tool dispatch (engine.ml:864-869):
                 Eio.Fiber.fork_promise ~sw:token.switch (fun () -> invoke_one call) *)
          let promise =
            Eio.Fiber.fork_promise ~sw (fun () ->
              (* Child reads the key. If propagation works, this is
                 "hello-from-parent". If not, None. *)
              Eio.Fiber.get test_key)
          in
          Eio.Promise.await_exn promise)
      in
      match result with
      | Some v when String.equal v "hello-from-parent" ->
        (* SPIKE PASS — Fiber.with_binding propagates into fork_promise. *)
        print_endline "[spike] PASS: fork_promise child saw parent's binding";
        print_endline "[spike] VERDICT: hybrid invoke_context model is viable";
        exit 0
      | Some other ->
        Printf.eprintf "[spike] FAIL: child saw unexpected value %S\n" other;
        exit 2
      | None ->
        (* SPIKE FAIL — propagation does NOT work. Must fall back to explicit
           ?invoke_context param on Engine.run_agent. *)
        Printf.eprintf "[spike] FAIL: fork_promise child did NOT inherit parent binding\n";
        Printf.eprintf "[spike] VERDICT: STOP — fall back to Engine.run_agent ?invoke_context\n";
        exit 2))
