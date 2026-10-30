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

(* -------------------------------------------------------------------------- *)
(* Image limits and validation                                                *)
(* -------------------------------------------------------------------------- *)

(** The largest image payload PAR carries inline in one block, in decoded
    bytes. Five mebibytes is the per-image cap Anthropic documents; OpenAI
    allows more, so this is the conservative default. Raise it per call when
    the provider in use accepts more. *)
let max_image_bytes = 5 * 1024 * 1024

(** The image MIME types PAR's providers can transmit. A type outside this list
    would be rejected downstream, so the data constructors reject it here and
    say so, instead of letting the provider fail far from the call site. *)
let supported_image_media_types =
  [ "image/png"; "image/jpeg"; "image/gif"; "image/webp" ]

let is_supported_image_media_type mt =
  List.mem mt supported_image_media_types

(** Infer an image MIME type from a file extension. Returns [None] for
    unknown extensions, in which case the caller should pass [?media_type]
    explicitly. *)
let media_type_of_extension ext =
  match String.lowercase_ascii ext with
  | ".png" -> Some "image/png"
  | ".jpg" | ".jpeg" -> Some "image/jpeg"
  | ".gif" -> Some "image/gif"
  | ".webp" -> Some "image/webp"
  | _ -> None

let supported_list () = String.concat ", " supported_image_media_types

let check_media_type ~what media_type =
  if is_supported_image_media_type media_type then Ok ()
  else Error (Printf.sprintf
      "%s: unsupported image media type %S (supported: %s)"
      what media_type (supported_list ()))

(* Base64 inflates by 4/3. Rejecting on the encoded length first means an
   oversized string is refused before we allocate a decoded copy of it. *)
let max_base64_length max_bytes = ((max_bytes + 2) / 3) * 4

let image_block ~source ~media_type ~detail : content_block =
  Image_block {
    source;
    media_type;
    data = "";
    detail;
    cache_control = None;
  }

let open_image_file (path : string) : (in_channel, string) result =
  try Ok (open_in_bin path) with Sys_error msg -> Error msg

let file_length (ic : in_channel) : (int, string) result =
  try Ok (in_channel_length ic) with Sys_error msg -> Error msg

let read_exact (ic : in_channel) (n : int) : (string, string) result =
  try Ok (really_input_string ic n) with
  | Sys_error msg -> Error msg
  | End_of_file -> Error "Unexpected end of file"

(** [image_base64 ~data ?media_type ?detail ?max_bytes ()] builds an image
    block from base64-encoded bytes already in hand.

    The payload is checked rather than trusted: it must be valid base64, it
    must not be empty, and its decoded length must not exceed [max_bytes]
    (default {!max_image_bytes}). The media type must be one of
    {!supported_image_media_types}. Returns [Error msg] with the reason.

    Payloads built by hand as an [Image_block] record are not re-checked at
    invoke time; this constructor is where the contract is established. *)
let image_base64 ~data ?(media_type = "image/png") ?detail
    ?(max_bytes = max_image_bytes) () : (content_block, string) result =
  if max_bytes <= 0 then Error "image_base64: max_bytes must be positive"
  else if String.length data > max_base64_length max_bytes then
    Error (Printf.sprintf
        "image_base64: encoded data is %d bytes, over the %d-byte image limit"
        (String.length data) max_bytes)
  else
    match check_media_type ~what:"image_base64" media_type with
    | Error _ as e -> e
    | Ok () ->
      (match Base64.decode data with
       | Error (`Msg msg) ->
         Error (Printf.sprintf "image_base64: not valid base64: %s" msg)
       | Ok decoded ->
         let n = String.length decoded in
         if n = 0 then Error "image_base64: empty image data"
         else if n > max_bytes then
           Error (Printf.sprintf
               "image_base64: decoded image is %d bytes, over the %d-byte image limit"
               n max_bytes)
         else Ok (image_block ~source:(Base64 data) ~media_type ~detail))

(** [image_file path ?media_type ?detail ?max_bytes ()] reads an image from
    disk and builds an image block with its contents base64-encoded.

    The [media_type] is inferred from the file extension when not given
    explicitly; an extension outside {!supported_image_media_types} is an
    error rather than a silent guess, so a caller cannot hand a mislabelled
    payload to a provider. Files larger than [max_bytes] (default
    {!max_image_bytes}) are rejected from their size, without reading them,
    and empty files are rejected as well.

    Returns [Error msg] when the file cannot be read or fails a check; the
    message states the path and the reason, and never leaks unrelated
    filesystem detail. *)
let image_file path ?media_type ?detail ?(max_bytes = max_image_bytes) ()
  : (content_block, string) result =
  if max_bytes <= 0 then Error "image_file: max_bytes must be positive"
  else
    let chosen =
      match media_type with
      | Some mt -> Result.map (fun () -> mt) (check_media_type ~what:"image_file" mt)
      | None ->
        (match media_type_of_extension (Filename.extension path) with
         | Some mt -> Ok mt
         | None ->
           Error (Printf.sprintf
               "image_file: cannot infer an image media type from %S; \
                pass ~media_type explicitly (supported: %s)"
               path (supported_list ())))
    in
    match chosen with
    | Error _ as e -> e
    | Ok mt ->
      (match open_image_file path with
       | Error msg -> Error msg
       | Ok ic ->
         Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
             let checked : (content_block, string) result =
               match file_length ic with
               | Error msg -> Error msg
               | Ok 0 -> Error (Printf.sprintf "image_file: %S is empty" path)
               | Ok n when n > max_bytes ->
                 Error (Printf.sprintf
                     "image_file: %S is %d bytes, over the %d-byte image limit"
                     path n max_bytes)
               | Ok n ->
                 (match read_exact ic n with
                  | Error msg -> Error (Printf.sprintf "%s: %s" path msg)
                  | Ok b ->
                    Ok (image_block
                          ~source:(Base64 (Base64.encode_string b))
                          ~media_type:mt ~detail))
             in
             checked))
