(lang dune 3.16)
(name par)
(version "0.7.3")
(generate_opam_files true)
(source (github jcz2020/par))
(license MIT)
(authors "P-A-R Contributors")
(maintainers "P-A-R Contributors")

(package
 (name par)
 (synopsis "Programmable Agent Runtime - SDK")
  (description "A modular, type-safe agent runtime for OCaml 5.4+ with multi-provider LLM support, ReAct engine, workflow orchestration, and strict state guarantees")
 (tags (agents llm runtime ffi))
  (depends
   ocaml
   dune
   base
   yojson
   eio
   eio_main
   uuidm
   ppx_deriving
   ppx_deriving_yojson
   (ppx_deriving_jsonschema (= "0.0.1"))
   ppx_sexp_conv
   ppx_compare
    sqlite3
    logs
  tls-eio
  cohttp-eio
  lambdasoup
  ca-certs
  x509
  mirage-crypto-rng
   base64
   digestif
    yaml
    omd
    camlpdf
    csv
    sexplib0
    ctypes
    alcotest
    jsonschema-validation))
