(** Tool-prompt rendering and synthesized-call parsing.

    PAR-k38 (T0.5). Pure module — no engine/provider wiring; the engine layer
    (T3.1) selects at runtime between [`Native] mode (provider wire
    protocol carries structured tool calls) and [`Synthesized] mode (this
    module's prompt text + parsing fallback).

    {1 Conventions}

    The synthesized-tool-call payload exchanged with the model has the shape:
    {[ {"tool_calls": [{"name": "<tool_name>", "arguments": {<json>}}]} ]}

    The renderer describes each tool as a [### name] section with its
    description and a pretty-printed [input_schema]. The parser is
    fence-tolerant (accepts [`\`\`\`json ... `\`\`\`] fences, bare JSON, and
    JSON embedded in prose) and never throws — on any parse failure it emits
    a [Logs.warn] and returns [[]]. *)

(** Render a list of tool descriptors as a "## Available Tools" prompt
    block suitable for injection into a system or developer message when the
    provider does not natively transport tool calls ([`Synthesized] mode).

    The output is plain markdown — one [### name] section per tool, plus a
    one-line JSON shape hint. If [tools] is empty, returns the header-only
    string (no per-tool sections). The function never fails. *)
val descriptors_to_prompt_text : Types.tool_descriptor list -> string

(** Extract tool calls from a model text response.

    Accepts the synthesized-tool-call payload in any of these positions:
    - Inside a [`\`\`\`json ... `\`\`\`] fenced block
    - Inside an unlabelled [`\`\`\` ... `\`\`\`] fenced block
    - As bare JSON on its own line
    - Embedded in surrounding prose

    Returns the parsed list of [Types.tool_call] values. Each parsed call
    has [id = ""] — the engine layer (T3.1) is responsible for assigning a
    real identifier when accepting the call.

    {b Never throws.} On any parse failure (malformed JSON, missing
    [tool_calls] field, wrong element types, etc.) returns [[]] and logs a
    warning via [Logs.warn]. The LLM response path must not be killed by a
    parser error. *)
val parse_tool_calls_from_text : string -> Types.tool_call list