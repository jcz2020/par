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
  let block = Message.image_base64 ~data:"aGk=" ~detail:"low" () in
  match content_block_of_yojson (content_block_to_yojson block) with
  | Ok decoded -> Alcotest.(check bool) "image survives JSON roundtrip" true (decoded = block)
  | Error message -> Alcotest.fail message

let failed_file_reads_close_channels () =
  if Sys.file_exists "/proc/self/fd" then begin
    let open_count () = Array.length (Sys.readdir "/proc/self/fd") in
    let before = open_count () in
    for _ = 1 to 32 do
      match Message.image_file (Filename.get_temp_dir_name ()) () with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "a directory is not an image file"
    done;
    Alcotest.(check int) "failed reads close their descriptors" before (open_count ())
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
