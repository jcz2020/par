(lang dune 3.16)
(name par)
(version "0.4.0-beta.20260613")
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
  uuidm
  ppx_deriving
  ppx_deriving_yojson
  ppx_sexp_conv
  ppx_compare
  caqti-eio
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
   alcotest))

(package
 (name par_cli)
 (synopsis "Programmable Agent Runtime - CLI tool")
 (description "CLI tool for the Programmable Agent Runtime — interactive REPL, config wizard, and single-shot query")
 (depends
  ocaml
  dune
  cmdliner
  par
  eio
  eio_main
  yojson
  mirage-crypto-rng
  alcotest))

(package
 (name par_postgres)
 (synopsis "Programmable Agent Runtime - PostgreSQL persistence backend")
 (description "PostgreSQL persistence backend for PAR. Shipped as a separate opam package.")
 (allow_empty)
 (depends
  ocaml
  dune
  par
  caqti-eio
  postgresql))

