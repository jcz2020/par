(* test/test_tls_client.ml — certificate identity targets.

   [Tls_client.connect] is the single TLS entry point for providers, MCP HTTP
   and the built-in HTTP tools. Its classifier decides whether a URL host is a
   DNS name (validated against SAN DNS entries) or an IP literal (validated
   against SAN IP entries). A host that is neither must fail closed: calling
   [Tls_eio.client_of_flow] without [~host]/[~ip] would check the chain but
   accept a certificate issued for any name. *)

open Par

let check_ip expected = function
  | Ok (`Ip ip) ->
    Alcotest.(check string) ("ip " ^ expected) expected (Ipaddr.to_string ip)
  | Ok (`Host _) -> Alcotest.failf "%s was classified as a domain name" expected
  | Error msg -> Alcotest.failf "%s was rejected: %s" expected msg

let test_ipv4 () =
  check_ip "192.168.1.5" (Tls_client.classify_host "192.168.1.5")

let test_ipv6 () =
  check_ip "::1" (Tls_client.classify_host "::1")

let test_domain () =
  match Tls_client.classify_host "api.openai.com" with
  | Ok (`Host h) ->
    Alcotest.(check string) "domain name" "api.openai.com"
      (Domain_name.to_string h)
  | Ok (`Ip _) -> Alcotest.fail "api.openai.com was classified as an IP"
  | Error msg -> Alcotest.failf "api.openai.com was rejected: %s" msg

let test_unparseable_host_fails_closed () =
  match Tls_client.classify_host "not a host" with
  | Error msg ->
    Alcotest.(check bool) "mentions refusing" true
      (let needle = "refusing" in
       let n = String.length needle in
       let rec go i =
         i + n <= String.length msg
         && (String.sub msg i n = needle || go (i + 1))
       in
       go 0)
  | Ok _ ->
    Alcotest.fail "an unparseable host must not be used for TLS without identity validation"

let () =
  Alcotest.run "test_tls_client" [
    ("classify_host", [
      Alcotest.test_case "IPv4 literal" `Quick test_ipv4;
      Alcotest.test_case "IPv6 literal" `Quick test_ipv6;
      Alcotest.test_case "domain name" `Quick test_domain;
      Alcotest.test_case "unparseable fails closed" `Quick
        test_unparseable_host_fails_closed;
    ]);
  ]
