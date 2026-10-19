open Types

let content_of_string s =
  if s = "" then []
  else [Text_block { text = s; cache_control = None }]

let string_of_content blocks =
  blocks
  |> List.filter_map (function
       | Text_block { text; _ } -> Some text
       | Tool_result_block { content; _ } -> Some content
       | _ -> None)
  |> String.concat ""

let text_of_message msg =
  string_of_content msg.content_blocks

let content_opt msg =
  let s = string_of_content msg.content_blocks in
  if s = "" then None else Some s

(* -------------------------------------------------------------------------- *)
(* Content block constructors                                                *)
(* -------------------------------------------------------------------------- *)

(** [text s] builds a plain text content block. *)
let text s : content_block =
  Text_block { text = s; cache_control = None }

(** [image_url url ?media_type ?detail ()] builds an image block that
    references a remotely hosted image. The provider fetches it; the bytes
    never travel through PAR. [media_type] defaults to ["image/png"] and
    [detail] is the provider-specific resolution hint (OpenAI accepts
    ["auto"], ["low"] or ["high"]; other providers ignore it). *)
let image_url url ?(media_type = "image/png") ?detail () : content_block =
  Image_block {
    source = Url url;
    media_type;
    data = "";
    detail;
    cache_control = None;
  }

(** [image_base64 ~data ?media_type ?detail ()] builds an image block from
    base64-encoded bytes already in hand. *)
let image_base64 ~data ?(media_type = "image/png") ?detail () : content_block =
  Image_block {
    source = Base64 data;
    media_type;
    data = "";
    detail;
    cache_control = None;
  }

(** Infer an image MIME type from a file extension. Returns [None] for
    unknown extensions, in which case the caller should pass [?media_type]
    explicitly. *)
let media_type_of_extension ext =
  match String.lowercase_ascii ext with
  | ".png" -> Some "image/png"
  | ".jpg" | ".jpeg" -> Some "image/jpeg"
  | ".gif" -> Some "image/gif"
  | ".webp" -> Some "image/webp"
  | ".bmp" -> Some "image/bmp"
  | _ -> None

(** [image_file path ?media_type ?detail ()] reads an image from disk and
    builds an image block with its contents base64-encoded.

    The [media_type] is inferred from the file extension when not given
    explicitly. Returns [Error msg] when the file cannot be read; the message
    states the path and the reason, and never leaks unrelated filesystem
    detail.

    This is the "local file becomes inline image" path. It is unbounded on
    purpose — callers that need a limit should check the file size before
    calling. *)
let image_file path ?media_type ?detail () : (content_block, string) result =
  let bytes =
    try
      let ic = open_in_bin path in
      let len = in_channel_length ic in
      let b = really_input_string ic len in
      close_in ic;
      Ok b
    with Sys_error msg -> Error msg
       | End_of_file -> Error (Printf.sprintf "Unexpected end of file: %s" path)
  in
  match bytes with
  | Error msg -> Error msg
  | Ok b ->
    let ext = Filename.extension path in
    let mt =
      match media_type with
      | Some m -> m
      | None ->
        (match media_type_of_extension ext with
         | Some m -> m
         | None -> "image/png")
    in
    Ok (image_base64 ~data:(Base64.encode_string b) ~media_type:mt ?detail ())
