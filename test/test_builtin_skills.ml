open Par
open Par.Types

(* test/test_builtin_skills.ml — regression guard for silent tool_filter typos.

   Bug history (fixed 2026-07-02): the builtin `code-reviewer` skill listed
   "read_file" and "glob" in its tool_filter Only-list, but the actual tool
   names are "read" and "find". Separately, the builtin `rag-assistant` skill
   listed "add_documents" and "invoke_with_rag", which are FFI callbacks /
   Runtime methods, not tool_descriptors. In both cases the filter at
   runtime.ml:400-405 (pure List.mem on tool_descriptor.name) silently zeroed
   the skill's usable tool set. No test caught either, because none
   cross-checked builtin skill tool_filters against real tool names.

   Invariant: for every builtin skill with tool_filter = Only [...], each name
   must resolve to a real builtin tool_descriptor.name. Builtin skills ship
   with the runtime and can only meaningfully reference tools that also ship
   with the runtime; a skill needing a user-registered tool does not belong in
   Builtin_skills. *)

let collect_only_filter_violations ~real_names =
  List.concat_map
    (fun (s : skill_descriptor) ->
      match s.tool_filter with
      | All_tools | Except _ -> []
      | Only allowed ->
        List.filter_map
          (fun name ->
            if List.mem name real_names then None
            else Some (s.id ^ ":" ^ name))
          allowed)
    Builtin_skills.builtin_skills

let test_only_filters_resolve_to_real_tools () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let net = (Eio.Stdenv.net env :> [ `Generic ] Eio.Net.ty Eio.Net.t) in
      let ws = match Workspace.of_cwd () with Ok w -> w | Error _ -> failwith "ws" in
      let tools = Builtin_tools.builtin_tools ~switch:sw ~net ~workspace:ws in
      let real_names =
        List.map (fun (tb : tool_binding) -> tb.descriptor.name) tools
      in
      match collect_only_filter_violations ~real_names with
      | [] -> ()
      | bad ->
        let msg =
          Printf.sprintf
            "builtin skill tool_filter references unknown tool name(s): %s \
             — every Only[...] entry must match a builtin tool_descriptor.name \
             (the filter at runtime.ml does pure List.mem, so a mismatch \
             silently zeroes the skill's tool set)"
            (String.concat ", " bad)
        in
        Alcotest.fail msg))

let () =
  Alcotest.run "builtin_skills" [
    ("builtin_skills", [
      Alcotest.test_case
        "all Only-filter tool names resolve to real builtin tools"
        `Quick
        test_only_filters_resolve_to_real_tools;
    ]);
  ]
