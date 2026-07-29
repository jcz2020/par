type memory_object = {
  id : string;
  content : string;
  summary : string option;
  scope : string option;
  metadata : (string * Yojson.Safe.t) list;
  categories : string list;
  created_at : float;
  updated_at : float;
  (** When this memory was last retrieved via [search_fn] / [list_all_fn].
      [None] on freshly inserted entries until first retrieval. Maintained
      automatically by [Sqlite_memory.bump_usage]. Exposed so consumers can
      explain [list_all] ordering (which sorts by [last_used_at DESC, usage_count DESC]). *)
  last_used_at : float option;
  (** How many times this memory has been retrieved. Incremented by
      [Sqlite_memory.bump_usage] on every [search_fn] / [list_all_fn] hit.
      Affects [list_all] ordering. [of_yojson] defaults to [0] when the
      field is absent (backward compat with pre-v0.8.0 JSON). *)
  usage_count : int;
  source : string;
}

val to_yojson : memory_object -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (memory_object, string) result
