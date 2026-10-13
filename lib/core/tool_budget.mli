(** Token-budget estimation for tool schemas.

    Provides {!estimate_tokens}, a heuristic that counts characters across
    each tool descriptor's name, description, and [input_schema] JSON,
    then divides by 4. This is an ESTIMATE — real tokenization varies by
    model. Used by the engine's progressive-mode seam to decide whether
    the full tool set fits within a caller-configured token budget. *)

val estimate_tokens : Types.tool_descriptor list -> int
(** [estimate_tokens descs] returns an estimated token count for the
    given list of tool descriptors. The heuristic sums
    [String.length(name) + String.length(description) + String.length(input_schema_json)]
    per tool, then divides by 4 (floor, minimum 1 per tool). *)
