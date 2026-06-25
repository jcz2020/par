<!-- language: en -->

# Tutorial 5: Session Resume

> **Status**: Stub. The full content ships after v0.5.4 Track B Phase B.2 (CLI
> flags for session resume) lands.
> **Tracked in**: [`.sisyphus/plans/v0.5.4-execution.md`](../../.sisyphus/plans/v0.5.4-execution.md)
> Task 7.
> **Depends on**: the `conversations` persistence table (B.0), the
   `Runtime.save_conversation` / `load_conversation` API (B.1), and the
   `par -c <id>` / `par -r` CLI flags (B.2).

This tutorial will demonstrate a conversation that survives a process restart.
Today every PAR session is ephemeral and lives only in memory, so closing the
process forgets everything. Once Track B lands, the conversation is written to
the persistence layer keyed by a session id, and a later process can reload it.

The planned walkthrough:

1. Start a session and tell it something to remember.
   ```bash
   par ask "Remember the number forty-two."
   ```
2. Note the session id the runtime prints.
3. Exit the process. Restart it later, even on a different day.
4. Resume by id, or resume the most recent session.
   ```bash
   par -c <session-id>
   par -r
   ```
5. Verify the context survived: ask "what number did I tell you?" and get back
   the value you set in step 1.

The persistence backing the resume is a whole-blob schema on the conversations
table, not event replay. Event replay cannot reconstruct a conversation, because
the event log does not carry message content. Direct persistence sidesteps that
impossibility.

**Until B.2 ships**: sessions are in-memory only. Closing the process, or even
letting the runtime drop out of scope, loses the conversation. For stateless
single-shot use, [Tutorial 1: RAG Q&A Bot](01-rag-qa-bot.md) shows the pattern
that works today: ground each answer in retrieved documents rather than in prior
turns.
