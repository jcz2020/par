open Types

(** Apply a context management strategy to a conversation.

    Returns [Ok conv] with the (possibly reduced) conversation,
    or [Error _] on failure. *)
val apply_strategy :
  context_strategy -> conversation -> llm_service option ->
  on_event:(event -> unit) option ->
  (conversation, error_category) result

(** Rough token estimation for a conversation.

    Counts characters in all content fields and tool_calls JSON,
    divides by 4 (average chars per token). *)
val estimate_tokens : conversation -> int

(** Truncate a conversation to fit within a token budget.

    Drops oldest non-system messages until under [max_tokens].
    Always keeps at least [min_messages].  When [keep_system] is
    true (default), system messages are preserved at the front. *)
val truncate_conversation :
  ?keep_system:bool -> min_messages:int -> max_tokens:int ->
  conversation -> conversation
