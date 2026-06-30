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

(** {1 PAR-p70: Auto Context Compression by Window Ratio}

    Pure helpers for ratio-based compression triggering. The engine
    (Task 5) calls [should_compress] before each LLM call; if it returns
    true, the engine applies the configured [context_strategy] (or the
    default Summarize via [apply_default_summarize] when no strategy
    is set). *)

(** Static lookup table mapping model names to context-window sizes.

    Used as tier-1 fallback when [llm_service.context_window_fn] is [None]
    and the user has not supplied [context_window_override].

    The match is case-insensitive substring on [model_config.model_name].
    Unknown models return 8000 (safe conservative default — forces early
    compression rather than risking [Context_length_exceeded]). *)
val default_context_window : model_config -> int

(** Three-tier context-window resolver: user_override → provider cap → static table.

    Returns 0 only when all three tiers fail (unknown model, no capability
    function, no override). Callers should treat 0 as "window unknown —
    skip auto-compression" (the engine emits [Context_compression_skipped
    `No_window_size]). *)
val resolve_context_window :
  llm:llm_service ->
  model:model_config ->
  user_override:int option ->
  int

(** Token estimate with 1.2× safety margin.

    The underlying [estimate_tokens] uses chars/4, which underestimates real
    tokens by ~20% (tool-call envelopes, role markers, JSON formatting
    overhead). This applies a 1.2× margin — conservative; Letta uses 1.3×. *)
val estimated_tokens_with_margin : conversation -> int

(** PURE decision function — no I/O, no side effects.

    Returns [(true, None)] when compression should fire.
    Returns [(false, Some reason)] when skipping, with a typed reason
    for the engine to emit via [Context_compression_skipped].
    Returns [(false, None)] when threshold is [None] (manual mode —
    the engine should apply [context_strategy] unconditionally instead). *)
val should_compress :
  threshold:float option ->
  cooldown:int option ->
  llm:llm_service ->
  model:model_config ->
  conv:conversation ->
  iterations_since_last_compress:int ->
  window_override:int option ->
  bool * context_compression_skip_reason option

(** Default compression action when [context_strategy] is [None] but
    the ratio threshold fires.

    Wraps [apply_summarize] with [max_tokens=8000] (post-summary target
    size) and [summary_model=None] (use the agent's own model). Users
    who want a different behavior should set [context_strategy] explicitly. *)
val apply_default_summarize :
  llm:llm_service ->
  on_event:(event -> unit) option ->
  conversation ->
  (conversation, error_category) result
