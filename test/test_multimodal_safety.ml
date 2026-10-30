open Par
open Types

let legacy_image () =
  let json = `List [`String "Image_block"; `Assoc [
    "source", `List [`String "Url"; `String "https://example.com/a.png"];
    "media_type", `String "image/png";
    "data", `String "";
    "cache_control", `Null;
  ]] in
  match content_block_of_yojson json with
  | Ok (Image_block { detail = None; _ }) -> ()
  | Ok _ -> Alcotest.fail "legacy image decoded incorrectly"
  | Error message -> Alcotest.fail message

let current_image () =
  match Message.image_base64 ~data:"aGk=" ~detail:"low" () with
  | Error message -> Alcotest.fail ("unexpected image error: " ^ message)
  | Ok block ->
    match content_block_of_yojson (content_block_to_yojson block) with
    | Ok decoded -> Alcotest.(check bool) "image survives JSON roundtrip" true (decoded = block)
    | Error message -> Alcotest.fail message

let failed_file_reads_close_channels () =
  if Sys.file_exists "/proc/self/fd" then begin
    let open_count () = Array.length (Sys.readdir "/proc/self/fd") in
    (* A supported extension so the check reaches [open_in_bin]: on Linux a
       directory opens read-only and fails when read, which is the path that
       has a descriptor to leak. *)
    let dir = Filename.temp_file "par_dir" ".png" in
    Sys.remove dir;
    Unix.mkdir dir 0o700;
    Fun.protect ~finally:(fun () -> Unix.rmdir dir) (fun () ->
        let before = open_count () in
        for _ = 1 to 32 do
          match Message.image_file dir () with
          | Error _ -> ()
          | Ok _ -> Alcotest.fail "a directory is not an image file"
        done;
        Alcotest.(check int) "failed reads close their descriptors" before (open_count ()))
  end

let () =
  Alcotest.run "multimodal safety" [
    "persistence", [
      Alcotest.test_case "legacy images without detail still decode" `Quick legacy_image;
      Alcotest.test_case "new images preserve detail through JSON" `Quick current_image;
    ];
    "file cleanup", [
      Alcotest.test_case "errors close the opened channel" `Quick failed_file_reads_close_channels;
    ];
  ]
