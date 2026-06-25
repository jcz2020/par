<!-- language: en -->

# Tutorial 4: Multi-Provider Fallback

> **Status**: Stub. The full content ships after v0.5.4 Track A Phase A.3
> (cross-provider fallback policy) lands.
> **Tracked in**: [`.sisyphus/plans/v0.5.4-execution.md`](../../.sisyphus/plans/v0.5.4-execution.md)
> Task 6c.
> **Depends on**: the `fallback_policy` ADT plus a `Provider_fallback_attempted`
> event, neither of which has shipped yet.

This tutorial will demonstrate configuring two providers (OpenAI as primary,
Anthropic as standby), then triggering a fallback when the primary returns
`Rate_limited`. You will subscribe to the `Provider_fallback_attempted` event for
observability so a dashboard can show when and why the runtime switched.

The planned walkthrough:

1. Register both providers in one config, mark OpenAI as the default.
2. Configure a `fallback_policy` that retries on `Rate_limited` and
   `External_failure`, then crosses over to the standby provider.
3. Drive the primary into a rate limit and watch the runtime fail over
   transparently.
4. Subscribe to `Provider_fallback_attempted` and log every crossover.

**Until A.3 ships**: PAR holds one active provider per runtime. Switching is
manual via the CLI or the registry API. See the provider integration material in
the [how-to guides](../howto/custom-llm-provider.md) for current single-provider
usage, and [Tutorial 1: RAG Q&A Bot](01-rag-qa-bot.md) for a runnable end-to-end
example against one provider.
