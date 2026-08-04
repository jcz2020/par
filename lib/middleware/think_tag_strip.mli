(** Middleware that strips [<think>] and [<reasoning>] tags from LLM responses.

    Reasoning models (DeepSeek R1, QwQ, etc.) embed chain-of-thought in
    these tags. This middleware cleans them from [resp.text] via the
    [on_after_llm] hook, preventing think-tag pollution in conversation
    history and user-visible output.

    Usage:
{[
let agent = Runtime.make_agent
  ~id:"my-agent"
  ~middleware:[Think_tag_strip.create ()]
  ...
]}
    Opt-in — only affects agents that include this middleware. *)
val create : unit -> Types.middleware_hook
