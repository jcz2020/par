type parsed_url = { host : string; port : int; path : string; use_tls : bool }

type http_error =
  | Invalid_input of string
  | Permission_denied of string
  | Rate_limited
  | Timeout
  | External_failure of string

val parse_url : string -> parsed_url

val build_http_request :
  host:string -> path:string -> headers:(string * string) list -> body:string -> string

val split_response : string -> string * string

val parse_status_line : string -> int

val headers_contain : needle:string -> string -> bool

val decode_chunked : string -> string

val decode_body : string -> string -> string

val map_http_status : int -> string -> http_error

val tls_config : Tls.Config.client lazy_t

val tls_host_of_string : string -> [ `host ] Domain_name.t option

val do_request :
  [ `Generic] Eio.Net.ty Eio.Net.t -> parsed_url -> string -> string

exception Http_status_error of int * string

val do_request_streaming :
  [ `Generic] Eio.Net.ty Eio.Net.t ->
  parsed_url ->
  string ->
  (status:int ->
   headers:string ->
   read_line:(unit -> string option) ->
   'a) ->
  'a

val do_request_streaming_with_flow :
  _ Eio.Flow.source ->
  (status:int ->
   headers:string ->
   read_line:(unit -> string option) ->
   'a) ->
  'a

val set_clock : 'a -> unit
val set_request_timeout : float -> unit

val with_timeout_for :
  timeout:float -> Eio.Switch.t -> (unit -> 'a) -> 'a
