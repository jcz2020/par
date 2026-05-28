(lang dune 3.16)
(name par)
(generate_opam_files true)
(source (github jcz2020/par))
(license MIT)
(authors "P-A-R Contributors")
(maintainers "P-A-R Contributors")

(package
 (name par)
 (synopsis "Programmable Agent Runtime - SDK")
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
  postgresql
  logs
  str
  unix
  tls-eio
  cohttp-eio
  lambdasoup
  ca-certs
  x509
  mirage-crypto-rng
  base64
  digestif))

(package
 (name par_cli)
 (synopsis "Programmable Agent Runtime - CLI tool")
 (depends
  ocaml
  dune
  cmdliner
  par
  eio
  eio_main
  yojson
   mirage-crypto-rng))
