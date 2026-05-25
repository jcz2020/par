open Par_core

let run config_path =
  Printf.printf "P-A-R Runtime starting with config: %s\n" config_path;
  0

let config_path =
  let open Cmdliner in
  Arg.(required & opt (some string) None &
    info [ "config"; "c" ] ~docv:"CONFIG_PATH" ~doc:"Path to runtime configuration file")

let cmd =
  let open Cmdliner in
  Cmd.v (Cmd.info "par" ~version:"0.1.0" ~doc:"P-A-R: Programmable Agent Runtime")
    Term.(const run $ config_path)
