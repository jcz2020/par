open Types

(** Normalize every assistant tool_call's [arguments] to a JSON object.

    Handles both the [tool_calls] field and [Tool_use_block] content.  Providers
    reject a function call whose arguments are [null], a list, or a scalar.
    Malformed model output is represented as [{}] instead, which lets schema
    validation produce an actionable tool error rather than poisoning every
    later request.  Non-object arguments are logged with the tool_call id and
    name. *)
val normalize_arguments : conversation -> conversation

(** Repair tool_call/tool_result pairing after a conversation cut.

    Handles both [tool_calls] + Tool-role messages and
    [Tool_use_block]/[Tool_result_block] content.  Drops orphan results and
    synthesizes a result for every call that lost its result, then normalizes
    arguments.  The result satisfies {!validate}. *)
val repair_tool_pairs : conversation -> conversation

(** Strict provider-replay validation.

    Checks that every result has a preceding tool_call, that every tool_call
    has a matching result before the next non-result message (or the end of the
    conversation), and that no arguments are non-objects.  Returns a message
    containing the offending tool_call id and name (when available).  Does not
    modify the conversation.

    Handoff calls are ordinary tool calls: the engine appends their
    `<handoff>` result before switching agents.  A dangling handoff is reported
    rather than silently accepted. *)
val validate : conversation -> (unit, string) result
