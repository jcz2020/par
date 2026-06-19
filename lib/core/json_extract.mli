(** Lenient JSON extraction from free-form LLM responses.

    Handles three common LLM output patterns:
    - Plain JSON: [{{"name": "Alice"}}]
    - Markdown-fenced JSON: [```json ... ```] or [``` ... ```]
    - JSON embedded in prose: [Sure! Here's the answer: {{...}}.]

    Returns [Error msg] if no valid JSON can be extracted. *)
val extract_json_from_text : string -> (Yojson.Safe.t, string) result
