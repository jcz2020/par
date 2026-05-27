(lang dune 3.16)
(name par)
(generate_opam_files true)
(source (github par-runtime/par))
(license MIT)
(authors "P-A-R Contributors")
(maintainers "P-A-R Contributors")

(package
 (name par_core)
 (synopsis "Programmable Agent Runtime - Core types and engine")
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
   ppx_compare))

(package
 (name par_eio)
 (synopsis "Programmable Agent Runtime - Eio concurrency primitives")
 (depends
  ocaml
  dune
  eio
  par_core))

(package
 (name par_sqlite)
 (synopsis "Programmable Agent Runtime - SQLite persistence backend")
 (depends
  ocaml
  dune
  caqti-eio
  sqlite3
  par_core
  par_eio))

(package
 (name par_postgres)
 (synopsis "Programmable Agent Runtime - PostgreSQL persistence backend")
 (depends
  ocaml
  dune
  postgresql
  par_core
  par_eio))

(package
 (name par_openai)
 (synopsis "Programmable Agent Runtime - OpenAI LLM provider")
 (depends
  ocaml
  dune
  eio
  yojson
  tls-eio
  par_core))

(package
 (name par_anthropic)
 (synopsis "Programmable Agent Runtime - Anthropic LLM provider")
 (depends
  ocaml
  dune
  eio
  yojson
  tls-eio
  par_core))

(package
 (name par_middleware)
 (synopsis "Programmable Agent Runtime - Default middleware collection")
 (depends
  ocaml
  dune
  eio
  par_core))

(package
 (name par_cli)
 (synopsis "Programmable Agent Runtime - CLI tool")
 (depends
  ocaml
  dune
  cmdliner
  par_core
  par_eio
  par_sqlite
  par_openai
  par_anthropic
  yojson
  eio))
