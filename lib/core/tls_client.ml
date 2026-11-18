(* TLS client setup shared by the provider, MCP HTTP and built-in HTTP tools.

   Certificate *identity* validation needs the name the caller intended to
   reach. [Tls_eio.client_of_flow] only validates it when given [~host] (DNS)
   or [~ip] (IP literal); called without either, it validates the chain but
   accepts a certificate issued for any name. Every TLS entry point therefore
   goes through [connect], and a host that is neither a domain name nor an IP
   address fails closed instead of silently downgrading to chain-only checks. *)

type target =
  [ `Host of [ `host ] Domain_name.t
  | `Ip of Ipaddr.t ]

let classify_host host =
  match Ipaddr.of_string host with
  | Ok ip -> Ok (`Ip ip)
  | Error _ ->
    match Domain_name.of_string host with
    | Ok dn ->
      (match Domain_name.host dn with
       | Ok h -> Ok (`Host h)
       | Error _ ->
         Error (Printf.sprintf
                  "TLS: %S is neither a domain name nor an IP address; refusing to connect without certificate identity validation"
                  host))
    | Error _ ->
      Error (Printf.sprintf
               "TLS: %S is neither a domain name nor an IP address; refusing to connect without certificate identity validation"
               host)

(* System trust anchors. A failure to load them means the certificate chain
   cannot be validated at all. The only safe outcome is to refuse the
   connection: falling back to an authenticator that accepts every chain would
   turn a broken trust store into a silent MITM downgrade. *)
let config_of_ca_result :
    (X509.Authenticator.t, [> `Msg of string ]) result ->
    (Tls.Config.client, string) result = function
  | Error (`Msg msg) ->
    Error
      (Printf.sprintf
         "TLS: cannot load the system CA certificates (%s); refusing to connect without certificate validation"
         msg)
  | Ok authenticator ->
    (match Tls.Config.client ~authenticator () with
     | Ok cfg -> Ok cfg
     | Error (`Msg msg) -> Error ("TLS configuration error: " ^ msg))

(* Shared by every TLS entry point (provider HTTP, MCP HTTP, built-in HTTP
   tools). Lazily loaded once per process; a failure raises at connection time
   instead of degrading certificate validation. *)
let config : Tls.Config.client Lazy.t =
  lazy
    (match config_of_ca_result (Ca_certs.authenticator ()) with
     | Ok cfg -> cfg
     | Error msg -> failwith msg)

let connect ~cfg uri flow =
  match Uri.host uri with
  | None ->
    failwith
      "TLS: URL has no host; refusing to connect without certificate identity validation"
  | Some host ->
    match classify_host host with
    | Ok (`Host h) -> Tls_eio.client_of_flow cfg ~host:h flow
    | Ok (`Ip ip) -> Tls_eio.client_of_flow cfg ~ip flow
    | Error msg -> failwith msg
