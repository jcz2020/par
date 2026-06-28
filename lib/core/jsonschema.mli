(* PAR — JSON Schema conventions (OpenAI strict-mode wrapper).

   The ppx_deriving_jsonschema generator produces schemas that are
   already "almost" OpenAI-strict-compatible (sets `additionalProperties`,
   tracks `required`), but the strict-mode spec is a small superset of
   what the ppx emits by default. This module is the single, auditable
   place that applies the wrapping rules.

   The wrapper is intentionally minimal and Yojson-only — it does not
   re-derive schemas, does not validate the input, and does not
   normalise schema keywords beyond what OpenAI strict mode requires.
   Caller responsibility: do not pass a malformed JSON Schema here and
   expect miracles. *)

(** {1 Strict-mode wrapper} *)

val to_strict_object_schema : Yojson.Safe.t -> Yojson.Safe.t
(** Wrap a derived JSON Schema so that it is compatible with OpenAI
    "strict" tool/function mode.

    Rules applied (only when the top-level value is `` `Assoc _ `` and
    has [type = "object"]):
    - Force ["additionalProperties"] to [`Bool false].
    - Union every key in ["properties"] into ["required"] (regardless of
      whether the field is ``option`` or has a default — the ppx
      already excludes those from `properties`/`required` in the way
      OpenAI expects, so we are merely being defensive).

    Pass-through behaviour:
    - Any non-`` `Assoc _ `` input (string, list, bool, …) is returned
      unchanged.
    - Any `` `Assoc _ `` whose ["type"] key is missing or not exactly
      [`String "object"] is returned unchanged — strict-mode wrapping
      only makes sense for object schemas.

    The function never raises. *)
