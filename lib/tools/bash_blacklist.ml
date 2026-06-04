(* lib/tools/bash_blacklist.ml — v0.3.1
   Last-resort blacklist. Data-only. NOT bulletproof. *)

type entry = {
  name : string;
  regex : Str.regexp;
  description : string;
}

let all = [
  (* Disk destruction (5) *)
  { name = "rm-rf-root";     regex = Str.regexp "rm[ \t]+-rf[ \t]+/";         description = "rm -rf / wipes the root filesystem" };
  { name = "rm-rf-home";     regex = Str.regexp "rm[ \t]+-rf[ \t]+~";         description = "rm -rf ~ wipes the user's home directory" };
  { name = "dd-zero-disk";   regex = Str.regexp "dd[ \t]+.*of=/dev/\\(sd\\|hd\\|nvme\\|vd\\)"; description = "dd writing to a raw block device zeros the disk" };
  { name = "mkfs";           regex = Str.regexp "mkfs\\.";                  description = "mkfs formats a filesystem (destructive)" };
  { name = "fdisk";          regex = Str.regexp "fdisk";                    description = "fdisk partitions a disk (destructive)" };

  (* System control (4) *)
  { name = "shutdown";       regex = Str.regexp "shutdown";                  description = "shutdown halts the system" };
  { name = "reboot";         regex = Str.regexp "reboot";                    description = "reboot restarts the system" };
  { name = "halt";           regex = Str.regexp "halt";                      description = "halt stops the system" };
  { name = "init-0";         regex = Str.regexp "init[ \t]+0";               description = "init 0 halts the system" };

  (* Privilege escalation (3) *)
  { name = "sudo";           regex = Str.regexp "^[ \t]*sudo[ \t]";           description = "sudo elevates privileges" };
  { name = "su-dash";        regex = Str.regexp "^[ \t]*su[ \t]+-";           description = "su - opens a root login shell" };
  { name = "doas";           regex = Str.regexp "doas";                      description = "doas elevates privileges" };

  (* Network exfil (4) *)
  { name = "curl-pipe-sh";   regex = Str.regexp "curl.*|.*sh";              description = "curl piped to sh downloads and executes remote code" };
  { name = "wget-pipe-sh";   regex = Str.regexp "wget.*|.*sh";              description = "wget piped to sh downloads and executes remote code" };
  { name = "nc-exec";        regex = Str.regexp "nc[ \t]+-e";                description = "nc -e spawns a reverse shell" };
  { name = "bash-reverse";   regex = Str.regexp "/dev/tcp/";                 description = "/dev/tcp/ is bash's TCP socket (reverse shell primitive)" };

  (* Fork bomb (1) *)
  { name = "fork-bomb";      regex = Str.regexp ":\\(\\)\\{:\\|:&\\}:";       description = "fork bomb :(){:|:&}: exhausts process table" };

  (* Permission bombs (3) *)
  { name = "chmod-777-root"; regex = Str.regexp "chmod[ \t]+\\(-R[ \t]+\\)?777[ \t]+/"; description = "chmod 777 / makes everything world-writable" };
  { name = "chmod-suid";     regex = Str.regexp "chmod[ \t]+[0-9]*[4-7][4-7][4-7][4-7]*[0-9]*[ \t]+/"; description = "chmod with 3+ setuid/setgid bits on /" };
  { name = "chown-recursive";regex = Str.regexp "chown[ \t]+-R";             description = "chown -R changes ownership recursively" };

  (* Eval injection vectors (3) *)
  { name = "bash-eval";      regex = Str.regexp "eval[ \t]+\\$";             description = "eval $var executes arbitrary code from a variable" };
  { name = "backtick-subst"; regex = Str.regexp "`.*`";                      description = "backtick substitution executes the enclosed command" };
  { name = "dollar-paren";   regex = Str.regexp "\\$\\(.*\\)";               description = "$(...) command substitution executes the enclosed command" };

  (* Filesystem loops (2) *)
  { name = "mount-bind";     regex = Str.regexp "mount[ \t]+--bind";         description = "mount --bind can create filesystem loops" };
  { name = "umount-force";   regex = Str.regexp "umount[ \t]+-f";            description = "umount -f force-unmounts (can disrupt running services)" };

  (* Crypto / mining (3) *)
  { name = "xmrig";          regex = Str.regexp "xmrig";                    description = "xmrig is a cryptocurrency miner" };
  { name = "minerd";         regex = Str.regexp "minerd";                   description = "minerd is a cryptocurrency miner" };
  { name = "stratum-tcp";    regex = Str.regexp "stratum\\+tcp://";         description = "stratum+tcp:// is a mining pool URL" };

  (* Process signals (3) *)
  { name = "kill-init";      regex = Str.regexp "kill[ \t]+-9[ \t]+1";        description = "kill -9 1 kills init (systemd/PID 1)" };
  { name = "pkill-broad";    regex = Str.regexp "pkill[ \t]+-9[ \t]+-f";    description = "pkill -9 -f kills all processes matching a pattern" };
  { name = "killall-broad";  regex = Str.regexp "killall[ \t]+-9";           description = "killall -9 kills all processes with a name" };
]

let matches ~argv =
  let joined = String.concat " " argv in
  List.filter (fun (entry : entry) ->
    try ignore (Str.search_forward entry.regex joined 0); true
    with Not_found -> false
  ) all

let names_of entries = List.map (fun (e : entry) -> e.name) entries
