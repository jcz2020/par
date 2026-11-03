open Types

(** Normalize every assistant tool_call's [arguments] to a JSON object.

    Providers reject a function call whose arguments are [null], a list, or a
    scalar.  Malformed model output is represented as [{}] instead, which lets
    schema validation produce an actionable tool error rather than poisoning
    every later request.  Non-object arguments are logged with the tool_call
    id and name. *)
val normalize_arguments : conversation -> conversation

(** Repair the tool_call/tool_result pairing after a conversation cut.

    - drops Tool messages whose [tool_call_id] has no call in the kept window;
    - synthesizes a Tool result for every call that lost its result;
    - keeps the original order otherwise.

    The result satisfies {!validate}. *)
val repair_tool_pairs : conversation -> conversation

(** Strict provider-replay validation for the fatal direction.

    Checks that every Tool result has a preceding tool_call in the same
    assistant batch, and that no arguments are non-objects.  Returns a message
    containing the offending tool_call id and name (when available).  Does not
    modify the conversation.

    A tool_call with no Tool result is accepted: handoff calls are control flow
    and have no result.  Truncation-specific repair (which does synthesize
    missing results) lives in {!repair_tool_pairs}. *)
val validate : conversation -> (unit, string) result
