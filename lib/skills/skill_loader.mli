(** Filesystem skill discovery + YAML frontmatter parser.

    Parses skill.md files from ~/.par/skills/ and ./.par/skills/ into
    [skill_descriptor] records. Uses a minimal hand-rolled parser (no
    ocaml-yaml dependency) for the flat key-value frontmatter subset. *)

(** Directory paths for skill discovery. *)
val default_user_skills_dir : unit -> string
val default_project_skills_dir : unit -> string

(** Parse a single skill.md file. Validates schema_version, id matches
    directory name, description length. Returns Error on invalid input. *)
val parse_skill_file : path:string -> (Types.skill_descriptor, string) result

(** Discover all skills from both user and project directories.
    Precedence: project > user (same id → project wins). *)
val discover :
  ?user_dir:string -> ?project_dir:string ->
  unit -> Types.skill_descriptor list

(** Check if any skills directory mtime changed since last scan. *)
val mtime_scan_needed :
  ?user_dir:string -> ?project_dir:string ->
  unit -> bool

(** Update mtime cache (call after successful discover). *)
val update_mtime_cache :
  ?user_dir:string -> ?project_dir:string ->
  unit -> unit

(** Clear cache, forcing full rescan on next discover. *)
val force_reload : unit -> unit

(** Parse tool_filter from YAML value (exposed for testing). *)
val parse_tool_filter : string -> (Types.tool_filter, string) result

(** Parse skill_trigger from YAML value (exposed for testing). *)
val parse_trigger : string -> (Types.skill_trigger, string) result
