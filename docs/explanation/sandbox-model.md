# Bash execution and isolation

The `bash` tool runs a command the model asked for. This page states exactly
what PAR does to contain it, what it does not do, and why the line sits where it
does. It is deliberately explicit: an agent that believes it is confined when it
is not will be trusted with more than it should be.

## What a bash call goes through

After `Runtime.create`, `Runtime.install_bash_tool` registers the handler. Every
call then passes these stages, in order:

| # | Stage | What it does |
|---|-------|--------------|
| 1 | argv only | The tool takes `argv : string list`. There is no shell string, so no quoting or `;` parsing happens before PAR sees the command. |
| 2 | Workspace admission | `cwd` is validated by `Workspace.admit`: `..`, `:` and sensitive prefixes (`/etc`, `~/.ssh`, …) are rejected; an absolute path is accepted only under a workspace root. |
| 3 | Policy filter | `Coder` (default), `ReadOnly`, `ReadOnlyNoNet` or a custom `POLICY` decides allow/reject, and can rewrite the command. `Coder` rejects entries from `Bash_blacklist`. |
| 4 | Environment scrubbing | `Bash_policy.sanitize_env` drops `*secret*` / `*key*` / `*token*` / `*password*` / `*credential*` names and the `AWS_*`, `AZURE_*`, `GCP_*`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GITHUB_TOKEN` families. The filtered set is what the child actually receives. |
| 5 | Timeout | The per-call timeout defaults to 30s and is clamped to 600s. On expiry the child is killed and the tool returns `Timeout`. |
| 6 | Output handling | stdout/stderr are capped at 50KB and 2000 lines, and ANSI escapes are stripped. |
| 7 | Audit trail | `Bash_invoked` and `Bash_completed` events carry the argv, cwd, risk rating, exit code and duration. |

## What is not guaranteed

- **Filesystem confinement.** `cwd` is where the command starts, not a jail. A
  command can `cd /`, or read any path the PAR process can read. `Workspace`
  protects the file tools, which construct paths through
  `Workspace.sandboxed_path`; it cannot constrain a process that has already
  started.
- **Network isolation.** `ReadOnlyNoNet` rejects commands it recognises as
  network clients. That is a classifier, not a firewall: a script can open a
  socket without running `curl`.
- **Process-group cleanup.** The direct child is killed on timeout. Descendants
  it started are not reaped.
- **CPU and memory limits.** `POLICY.max_cpu_seconds` and `max_memory_kb` are
  declared and reported, but nothing enforces them today. Treat them as intent,
  not as a control.
- **Privilege drop.** The child runs with PAR's uid and gid.

## Why the gap exists

PAR runs on Linux, macOS and Windows, and the mechanisms that close these gaps
are platform-specific: bubblewrap or landlock on Linux, seatbelt (`sandbox-exec`)
on macOS, job objects on Windows. A library that silently degrades its isolation
per platform is worse than one that states the boundary, because callers cannot
tell which behaviour they got.

There is a second reason: PAR has no pre-exec hook. The reference monad that
would let a child install a landlock ruleset or a new process group between
`fork` and `exec` is not part of the process API PAR builds on.

## The pluggable design (not implemented)

The intended shape is an opt-in wrapper rather than a hidden default:

```ocaml
type sandbox = {
  name : string;
  (* Wrap the argv about to be spawned. *)
  wrap : argv:string list -> cwd:string -> (string list, error_category) result;
  (* What this implementation actually provides, so callers can report it. *)
  provides : [ `Filesystem | `Network | `Process_group | `Rlimits ] list;
}

val install_bash_tool : ?sandbox:sandbox -> ... -> (unit, error_category) result
```

Candidate implementations:

| Platform | Mechanism | Provides |
|----------|-----------|----------|
| Linux | `bwrap --unshare-all --ro-bind / / --bind <cwd> <cwd> -- <argv>` | filesystem, network, process group |
| Linux | landlock ruleset installed before `exec` | filesystem (needs a pre-exec hook or a small C stub) |
| macOS | `sandbox-exec -p <profile> <argv>` | filesystem, network |
| Windows | job object for CPU/memory limits | rlimits only |

Selection would be explicit and **fail closed**: requesting a sandbox whose
capability probe fails returns an error instead of quietly running unsandboxed.

## When this would be built

The trigger is a deployment that runs untrusted or multi-tenant commands. Until
then, the honest answer for untrusted input is isolation outside PAR — a
container, a VM, or a dedicated user — which is a deployment decision, not a
library feature.

## See also

- The SDK pages under `docs/sdk/`, starting with [Tools](../sdk/tools.md) for the
  bash tool's parameters and the safety table
- [Concurrency model](concurrency-model.md) — cancellation and timeouts
