<!-- language: en -->

**English** · [简体中文](https://github.com/jcz2020/par/blob/main/docs/zh/explanation/multimodal-completion.md)

# 2026-10-19: Complete multimodal input across SDK surfaces

**Before:** The first multimodal implementation exposed rich input only to the
OCaml SDK, even though the existing content-block codec already provided a JSON
representation. Image decoding also required the newly added `detail` key, so
older saved images failed to load. Failed local-file reads leaked open channels.

**After:** Both SDKs expose synchronous `Runtime.invoke_content`. Python helpers
produce the existing tagged-array content-block representation, and
`par_invoke_content` forwards it through the existing dispatch/response path with
explicit `save` and `update_current` flags. Invalid JSON or block shapes fail
before provider I/O. The shared runtime accepts text and image user blocks only;
tool-protocol blocks belong to the engine. Missing image `detail` defaults to
`None`. Local-file channels close on success and failure.

**Reason:** Deferring Python needed no unavailable dependency or technical spike;
it was a scope compromise, not a sound architectural boundary. Expanding this
feature now avoids maintaining incompatible SDK capabilities across releases.

**Decision classification:** Architecturally correct, one-shot completion
(STRATEGY §11 R1/R3). There is no remaining Python deferral for synchronous rich
input. Reusing the existing JSON representation avoids a second transport schema.

**Affected surface:** OCaml runtime validation, content-block JSON decoding,
message file helpers, OCaml/C bridge, ctypes declarations, Python content helpers
and exports, SDK documentation in both languages, and regression/integration tests.
The published v0.11 beta tag is unchanged. These changes remain development work;
no version bump or additional release is authorized by this decision.

The public facade in `lib/par.ml` exposes the runtime; usage examples live in
`docs/sdk/content_blocks.md` and `docs/sdk/agent.md`.

**Verification contract:** Tests exercise the complete Python → C → OCaml → local
HTTP-provider path, including URL/base64/local images, invalid inputs, legacy JSON,
unknown agents and persistence/current-state flags. OCaml regressions pin legacy
and current image decoding and descriptor cleanup after read failures.
The final local run collected 1634 OCaml tests and 174 passing Python tests, with
20 pre-existing Python skips and two pre-existing callback-memory warnings.

**Rollback:** Revert this completion change without rewriting existing tags.
Remove the new C symbol, Python helpers and method together; keep persisted image
decoding compatible if reverting would otherwise make saved conversations unreadable.
