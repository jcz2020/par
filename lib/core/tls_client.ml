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
