(lang dune 3.16)
(name par)
(version "0.8.3")
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
    ; ppx_deriving_jsonschema: pinned to 0.0.1 because ≥0.0.6 changed PPX code
    ; generation from inline JSON literals to runtime primitive references
    ; (would require `open Ppx_deriving_jsonschema_runtime.Primitives.Yojson`
    ; in every consumer source file), and ≥0.0.7 added melange +
    ; server-reason-react as hard dependencies — inappropriate for a pure
    ; native OCaml project. See CHANGES.md (v0.6.7 entry) for the incident
    ; that established this pin.
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
    camlzip
    xmlm
    csv
    sexplib0
    ctypes
    (alcotest :with-test)))
