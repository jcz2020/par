(** Last-resort blacklist of obviously catastrophic bash commands.

    This is a data-only module: a list of regex patterns + a matcher.
    It is NOT bulletproof. The primary security mechanism is the policy
    layer (Bash_policy). This list catches the catastrophic cases when
    the policy is permissive.

    Real-world security: blacklists are never complete. This is a
    tripwire, not a fence. *)

type entry = {
  name : string;
  regex : Str.regexp;
  description : string;
}

val all : entry list

(** Returns entries whose regex matches the joined argv (space-separated). *)
val matches : argv:string list -> entry list

(** Extract just the names from a list of entries (for error messages). *)
val names_of : entry list -> string list
