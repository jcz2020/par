(* GitHub #45 / PAR-lf60: the conversation store writes per-message rows and
   only rewrites the suffix that actually changed. These tests pin the two
   properties that matter: unchanged messages are not rewritten, and a changed
   prefix (context compression) is rewritten from the divergence point. *)

open Par
open Types

let tmp_db () =
  let p = Filename.temp_file "conv-store" ".db" in
  Sys.remove p;
  p

let msg text : message = {
  role = User;
  content_blocks = Message.content_of_string text;
  tool_calls = None;
  tool_call_id = None;
  name = None;
}

let conv ?(metadata = []) messages : conversation = { messages; metadata }

let texts (c : conversation) =
  List.map Message.text_of_message c.messages

let open_store db =
  match Sqlite_persistence.create db with
  | Ok t -> t
  | Error e ->
    Alcotest.failf "create: %s"
      (Yojson.Safe.to_string (error_category_to_yojson e))

let save ?scope t session_id conv =
  match Sqlite_persistence.save_conversation ?scope t session_id conv with
  | Ok () -> ()
  | Error e ->
    Alcotest.failf "save: %s"
      (Yojson.Safe.to_string (error_category_to_yojson e))

let load_exn t session_id : conversation =
  match Sqlite_persistence.load_conversation t session_id with
  | Ok (Some c) -> c
  | Ok None -> Alcotest.failf "conversation %s not found" session_id
  | Error e ->
    Alcotest.failf "load: %s"
      (Yojson.Safe.to_string (error_category_to_yojson e))

let load_opt t session_id =
  match Sqlite_persistence.load_conversation t session_id with
  | Ok c -> c
  | Error e ->
    Alcotest.failf "load: %s"
      (Yojson.Safe.to_string (error_category_to_yojson e))

let raw_db t = Sqlite_persistence.raw_sqlite3_db t

let raw_int t sql =
  let stmt = Sqlite3.prepare (raw_db t) sql in
  let v = match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Sqlite3.column_int stmt 0
    | _ -> Alcotest.failf "expected one row: %s" sql
  in
  ignore (Sqlite3.finalize stmt);
  v

let raw_text t sql =
  let stmt = Sqlite3.prepare (raw_db t) sql in
  let v = match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Sqlite3.column_text stmt 0
    | _ -> Alcotest.failf "expected one row: %s" sql
  in
  ignore (Sqlite3.finalize stmt);
  v

(* Overwrite one stored message behind the store's back. If a later save
   preserves that row, the save did not rewrite it. *)
let tamper t ~session_id ~seq text =
  let stmt =
    Sqlite3.prepare (raw_db t)
      "UPDATE conversation_messages SET message_json = ? \
       WHERE session_id = ? AND seq = ?"
  in
  let json = Yojson.Safe.to_string (message_to_yojson (msg text)) in
  let _ = Sqlite3.bind_text stmt 1 json in
  let _ = Sqlite3.bind_text stmt 2 session_id in
  let _ = Sqlite3.bind_int stmt 3 seq in
  let rc = Sqlite3.step stmt in
  let _ = Sqlite3.finalize stmt in
  match rc with
  | Sqlite3.Rc.DONE | Sqlite3.Rc.ROW -> ()
  | rc -> Alcotest.failf "tamper failed: %s" (Sqlite3.Rc.to_string rc)

let check_texts label expected c =
  Alcotest.(check (list string)) label expected (texts c)

let () =
  Alcotest.run "sqlite conversation store" [
    "conversations", [

      Alcotest.test_case "roundtrip_and_empty" `Quick (fun () ->
        let db = tmp_db () in
        let t = open_store db in
        let a = msg "a" in
        save t "s1" (conv [a]);
        check_texts "one message" ["a"] (load_exn t "s1");
        save t "s1" (conv []);
        let empty = load_exn t "s1" in
        Alcotest.(check int) "no messages" 0 (List.length empty.messages);
        Alcotest.(check int) "metadata row exists" 1
          (raw_int t "SELECT COUNT(*) FROM conversations WHERE session_id = 's1'");
        Alcotest.(check int) "no message rows" 0
          (raw_int t "SELECT COUNT(*) FROM conversation_messages WHERE session_id = 's1'");
        Alcotest.(check bool) "v2 layout" true
          (raw_int t "SELECT storage_version FROM conversations WHERE session_id = 's1'" = 2);
        Sqlite_persistence.close t);

      Alcotest.test_case "append_writes_only_the_suffix" `Quick (fun () ->
        let db = tmp_db () in
        let t = open_store db in
        let a = msg "a" and b = msg "b" and c = msg "c" in
        save t "s1" (conv [a; b]);
        tamper t ~session_id:"s1" ~seq:0 "TAMPERED-A";
        (* Same message records, one more at the end. *)
        save t "s1" (conv [a; b; c]);
        check_texts "prefix kept, suffix appended"
          ["TAMPERED-A"; "b"; "c"] (load_exn t "s1");
        Alcotest.(check int) "three rows" 3
          (raw_int t "SELECT COUNT(*) FROM conversation_messages WHERE session_id = 's1'");
        Sqlite_persistence.close t);

      Alcotest.test_case "compaction_rewrites_from_divergence" `Quick (fun () ->
        let db = tmp_db () in
        let t = open_store db in
        let a = msg "a" and b = msg "b" and c = msg "c" in
        let summary = msg "summary" in
        save t "s1" (conv [a; b; c]);
        tamper t ~session_id:"s1" ~seq:0 "TAMPERED-A";
        tamper t ~session_id:"s1" ~seq:1 "TAMPERED-B";
        (* Compression keeps the head, replaces the middle. *)
        save t "s1" (conv [a; summary; c]);
        check_texts "prefix kept, tail rewritten"
          ["TAMPERED-A"; "summary"; "c"] (load_exn t "s1");
        Alcotest.(check int) "still three rows" 3
          (raw_int t "SELECT COUNT(*) FROM conversation_messages WHERE session_id = 's1'");
        Sqlite_persistence.close t);

      Alcotest.test_case "metadata_only_update_skips_messages" `Quick (fun () ->
        let db = tmp_db () in
        let t = open_store db in
        let a = msg "a" in
        save t "s1" (conv [a]);
        tamper t ~session_id:"s1" ~seq:0 "TAMPERED-A";
        save t "s1" (conv ~metadata:[("k", `String "v")] [a]);
        let c = load_exn t "s1" in
        check_texts "message untouched" ["TAMPERED-A"] c;
        (match List.assoc_opt "k" c.metadata with
         | Some (`String "v") -> ()
         | _ -> Alcotest.fail "metadata not updated");
        Sqlite_persistence.close t);

      Alcotest.test_case "legacy_v1_row_loads_then_migrates" `Quick (fun () ->
        let db = tmp_db () in
        let t = open_store db in
        let legacy = msg "legacy" in
        let legacy_json =
          Yojson.Safe.to_string (`List [message_to_yojson legacy])
        in
        let stmt =
          Sqlite3.prepare (raw_db t)
            "INSERT INTO conversations \
             (session_id, messages_json, metadata_json, updated_at, turn_count, \
              scope, storage_version, writer_epoch) \
             VALUES ('old', ?, '{}', 0.0, 1, NULL, 1, NULL)"
        in
        let _ = Sqlite3.bind_text stmt 1 legacy_json in
        let rc = Sqlite3.step stmt in
        let _ = Sqlite3.finalize stmt in
        (match rc with
         | Sqlite3.Rc.DONE | Sqlite3.Rc.ROW -> ()
         | rc -> Alcotest.failf "legacy insert: %s" (Sqlite3.Rc.to_string rc));
        check_texts "legacy row readable" ["legacy"] (load_exn t "old");
        Alcotest.(check int) "no message rows yet" 0
          (raw_int t "SELECT COUNT(*) FROM conversation_messages WHERE session_id = 'old'");
        (* First save upgrades the row to the v2 layout. *)
        save t "old" (conv [legacy; msg "next"]);
        Alcotest.(check int) "migrated to v2" 2
          (raw_int t "SELECT storage_version FROM conversations WHERE session_id = 'old'");
        Alcotest.(check string) "legacy blob cleared" ""
          (raw_text t "SELECT messages_json FROM conversations WHERE session_id = 'old'");
        Alcotest.(check int) "two message rows" 2
          (raw_int t "SELECT COUNT(*) FROM conversation_messages WHERE session_id = 'old'");
        check_texts "migrated content" ["legacy"; "next"] (load_exn t "old");
        Sqlite_persistence.close t);

      Alcotest.test_case "epoch_conflict_forces_full_rewrite" `Quick (fun () ->
        let db = tmp_db () in
        let t1 = open_store db in
        let t2 = open_store db in
        let a = msg "a" and b = msg "b" and c = msg "c" in
        save t1 "s1" (conv [a; b]);
        (* Another handle rewrites the same session. A stale prefix from t1
           would turn the next save into [x; c]. *)
        save t2 "s1" (conv [msg "x"]);
        save t1 "s1" (conv [a; b; c]);
        check_texts "stale prefix discarded" ["a"; "b"; "c"] (load_exn t1 "s1");
        Sqlite_persistence.close t1;
        Sqlite_persistence.close t2);

      Alcotest.test_case "most_recent_uses_v2_rows_and_scope" `Quick (fun () ->
        let db = tmp_db () in
        let t = open_store db in
        save ~scope:"A" t "s-a" (conv [msg "from-a"]);
        save ~scope:"B" t "s-b" (conv [msg "from-b"]);
        (match Sqlite_persistence.load_most_recent_conversation ~scope:"A" t with
         | Ok (Some ("s-a", c)) -> check_texts "scoped load" ["from-a"] c
         | Ok (Some (sid, _)) -> Alcotest.failf "unexpected session %s" sid
         | Ok None -> Alcotest.fail "scoped conversation missing"
         | Error e ->
           Alcotest.failf "load_most_recent: %s"
             (Yojson.Safe.to_string (error_category_to_yojson e)));
        (match Sqlite_persistence.load_conversations t 10 with
         | Ok summaries ->
           Alcotest.(check int) "two conversations" 2 (List.length summaries)
         | Error e ->
           Alcotest.failf "load_conversations: %s"
             (Yojson.Safe.to_string (error_category_to_yojson e)));
        Sqlite_persistence.close t);

      Alcotest.test_case "turn_count_is_message_count" `Quick (fun () ->
        let db = tmp_db () in
        let t = open_store db in
        save t "s1" (conv [msg "a"; msg "b"; msg "c"]);
        Alcotest.(check int) "turn_count" 3
          (raw_int t "SELECT turn_count FROM conversations WHERE session_id = 's1'");
        Sqlite_persistence.close t);

      Alcotest.test_case "shortening_a_conversation_removes_rows" `Quick (fun () ->
        let db = tmp_db () in
        let t = open_store db in
        let a = msg "a" and b = msg "b" and c = msg "c" in
        save t "s1" (conv [a; b; c]);
        save t "s1" (conv [a; b]);
        check_texts "tail dropped" ["a"; "b"] (load_exn t "s1");
        Alcotest.(check int) "two rows left" 2
          (raw_int t "SELECT COUNT(*) FROM conversation_messages WHERE session_id = 's1'");
        Alcotest.(check bool) "unknown session" true (load_opt t "nope" = None);
        Sqlite_persistence.close t);
    ]
  ]
