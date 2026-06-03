# P0+P1 Re-Execution Plan

> Re-apply 9 lost fixes (4 P0 correctness + 5 P1 quality) on top of P2 working tree.
> Base commit: `62fee43` on main. P2 changes in working tree (uncommitted).
> Lost diffs recovered from `stash@{2}` (WIP on main: b2237af).

## Principles

1. **Never overwrite P2 changes** — only ADD P0/P1 content
2. **TDD** — each fix must compile and pass tests before next fix
3. **Atomic commits** — one commit per issue, grouped by wave
4. **Build verification** — `dune build` after every source change, `dune runtest` per wave

## Dependency Graph

```
P0-3 (types.ml: task_completion_of_yojson)
  └── P0-3 callers (all sites using task_completion_of_yojson)

P1-1 prep (types.ml: eval_limits + runtime_config)
  └── P1-1 (expression.ml: eval_limits parameter)
       └── P0-2 (workflow_engine + runtime + tests)
              └── bin/main.ml, examples/basic_agent.ml

P0-1 (cancellation.ml) ─── independent
P0-4 (sqlite + postgres + ffi) ─── independent
P1-3 (retry.ml + rate_limit.ml) ─── independent
P1-4 (validation.ml) ─── independent
```

Critical path: `P1-1 prep → P1-1 → P0-2 → tests`

## Conflict Risk Matrix

| File | P2 modified? | P0/P1 modifies? | Risk | Strategy |
|------|-------------|-----------------|------|----------|
| `lib/core/cancellation.ml` | NO | P0-1 | NONE | Direct edit |
| `lib/core/types.ml` | NO | P0-3, P1-1 | NONE | Different regions |
| `lib/core/types.mli` | NO | P0-3, P1-1 | NONE | Different regions |
| `lib/core/expression.ml` | NO | P1-1 | NONE | Direct edit |
| `lib/core/expression.mli` | NO | P1-1 | NONE | Direct edit |
| `lib/core/workflow_engine.ml` | NO | P0-2 | NONE | Direct edit |
| `lib/core/workflow_engine.mli` | NO | P0-2 | NONE | Direct edit |
| `lib/core/runtime.ml` | NO | P0-2 | NONE | Direct edit |
| `lib/core/runtime.mli` | NO | P0-2 | NONE | Direct edit |
| `lib/middleware/retry.ml` | NO | P1-3 | NONE | Direct edit |
| `lib/middleware/rate_limit.ml` | NO | P1-3 | NONE | Direct edit |
| `lib/middleware/validation.ml` | NO | P1-4 | NONE | Direct edit |
| `lib/persistence/sqlite_persistence.ml` | NO | P0-4 | NONE | Direct edit |
| `lib/persistence/postgres_persistence.ml` | NO | P0-4 | NONE | Direct edit |
| `lib/ffi/par_capi.ml` | NO | P0-4 | NONE | Direct edit |
| **`test/test_integration.ml`** | **YES** | P0-2,P1-3,P1-4 | **MEDIUM** | **APPEND only; never touch lines 617-741** |
| `bin/main.ml` | NO | P0-2 | NONE | Add eval_limits field |
| `examples/basic_agent.ml` | NO | P0-2 | NONE | Add eval_limits field |

**Key insight**: Only `test/test_integration.ml` has real conflict risk (P2 added 120 lines at 617-732). Everything else is clean.

---

## Wave 1 — Independent Files (5 parallel agents)

All files have **zero P2 modifications**. Agents can write freely.

### W1-A: P0-1 — `with_timeout` respects seconds param
**File**: `lib/core/cancellation.ml` (34 lines total, lines 16-28 affected)

**Diff** (from stash@{2}):
- Line 16: `_seconds` → `seconds`
- Lines 23-25: Replace instant Timeout/Cancelled with deadline loop:
```ocaml
(* BEFORE *)
(fun () ->
  if token.cancelled then result := Some (Error `Cancelled)
  else result := Some (Error `Timeout));

(* AFTER *)
(fun () ->
  let deadline = Unix.gettimeofday () +. seconds in
  while !result = None && not token.cancelled do
    if Unix.gettimeofday () >= deadline then
      result := Some (Error `Timeout)
    else
      Eio.Fiber.yield ()
  done;
  if token.cancelled && !result = None then
    result := Some (Error `Cancelled));
```

---

### W1-B: P0-4 — Remove `ignore()` from cleanup paths

**3 files, all no P2 changes**:

#### `lib/persistence/sqlite_persistence.ml`
| Line | Before | After |
|------|--------|-------|
| 59 | `ignore (Sqlite3.db_close db); Result.Error e` | `let ok = Sqlite3.db_close db in if not ok then Logs.err(...); Result.Error e` |
| 61 | `let close t = ignore (Sqlite3.db_close t.db)` | `let close t = let ok = Sqlite3.db_close t.db in if not ok then Logs.err(...)` |
| 231 | `Some json -> ignore (Sqlite3.bind_text stmt 4 json)` | Check `Sqlite3.Rc.OK`, log on error |
| 232 | `None -> ignore (Sqlite3.bind stmt 4 Sqlite3.Data.NULL)` | Check `Sqlite3.Rc.OK`, log on error |
| 284 | `exec_sql t.db "ROLLBACK" |> ignore` | `match exec_sql ... with Ok/ Error -> log` |

#### `lib/persistence/postgres_persistence.ml`
| Line | Before | After |
|------|--------|-------|
| 256 | `exec_sql t.db "ROLLBACK" |> ignore` | `match exec_sql ... with Ok/Error -> log` |

#### `lib/ffi/par_capi.ml`
| Line | Before | After |
|------|--------|-------|
| 40 | `ignore (Hashtbl.remove handles id)` | `Hashtbl.remove handles id` |
| 71 | `ignore (Par.Runtime.close handle.rt)` | `let _n = ... in ()` + `Logs.err` on exception |
| 95-97 | `ignore (Par.Runtime.register_tool ...)` | `let _tool = ... in` + inner try/catch with `Logs.err` |

---

### W1-C: P0-3 — `task_completion_of_yojson` returns Result

**2 files, no P2 changes**:

#### `lib/core/types.ml` (replace lines 686-706)
Replace `failwith`-based parsing with nested `Error`-returning:
```ocaml
(* Return type changes from `task_completion` to `(task_completion, string) result` *)
let task_completion_of_yojson : Yojson.Safe.t -> (task_completion, string) result =
  function
  | `Assoc xs ->
    (match List.assoc_opt "task_id" xs with
     | None -> Error "task_completion: missing task_id"
     | Some v ->
       (match Task_id.of_yojson v with
        | Error _ -> Error "task_completion: invalid task_id"
        | Ok task_id ->
          (* ... nested Result matching for result and elapsed ... *)))
  | _ -> Error "task_completion: expected object"
```

#### `lib/core/types.mli` (line 612)
```diff
-val task_completion_of_yojson : Yojson.Safe.t -> task_completion
+val task_completion_of_yojson : Yojson.Safe.t -> (task_completion, string) result
```

**IMPORTANT**: All callers of `task_completion_of_yojson` must be found and updated. Run:
```bash
grep -rn "task_completion_of_yojson" lib/ test/
```

---

### W1-D: P1-3 — Parameterize middleware configs

**2 files, no P2 changes**:

#### `lib/middleware/retry.ml`
1. Add `retry_config` type:
```ocaml
type retry_config = {
  max_attempts : int;
  base_delay : float;
  max_delay : float;
}
```
2. Add `default_retry_config` and `config_to_policy`
3. Change `retry` signature:
```diff
-let retry ?(policy = default_policy) () : middleware_hook =
+let retry
+    ?(config : retry_config = default_retry_config)
+    ?(policy : retry_policy option)
+    () : middleware_hook =
+  let effective_policy = match policy with
+    | Some p -> p
+    | None -> config_to_policy config
+  in
```
4. Replace all `policy.` references with `effective_policy.`

#### `lib/middleware/rate_limit.ml`
1. Add `rate_limit_config` type + `default_rate_limit_config`
2. Change signature:
```diff
-let rate_limit ?(max_requests = 60) ?(window_seconds = 60.0) () : middleware_hook =
+let rate_limit ?(config : rate_limit_config = default_rate_limit_config) () : middleware_hook =
+  let max_requests = config.max_requests in
+  let window_seconds = config.window in
```

---

### W1-E: P1-4 — Fix validation error swallowing

**1 file, no P2 changes**: `lib/middleware/validation.ml`

**Changes** (see full stash diff for exact code):
1. `on_after_llm` (lines 17-26): Return `Some { resp with text = Some "" }` instead of `None` for empty responses (repair, don't swallow)
2. `on_before_tool` strict (line 36-39): Add `Logs.err` call, use `repaired` variable
3. `on_before_tool` lenient (line 40-43): Don't add to `invalid_args` — repaired data passes through
4. Add comments explaining strict vs lenient behavior difference

---

## Wave 2 — Dependent Changes (sequential within, parallel between)

### W2-A: P1-1 prep — Add `eval_limits` type + update `runtime_config`

**Depends on**: Wave 1 complete (needs clean build)

**Files**: `lib/core/types.ml`, `lib/core/types.mli`

**types.ml** — Insert AFTER `shutdown_config` (~line 474), BEFORE `runtime_config`:
```ocaml
type eval_limits = {
  max_depth : int;
  max_node_visits : int;
}
[@@deriving yojson]
```

**types.ml** — Add field to `runtime_config` (line ~490):
```diff
 type runtime_config = {
   persistence : [ `Sqlite of string | `Postgresql of string ];
   event_bus : event_bus_config;
   default_quota : resource_quota;
   shutdown : shutdown_config;
   llm_providers : (string * llm_provider_config) list;
+  eval_limits : eval_limits;
 }
 [@@deriving yojson]
```

**types.mli** — Same two additions (after shutdown_config section, in runtime_config type).

**This breaks the build** — all `runtime_config` literals need `eval_limits` field. Fix immediately in:
- `lib/core/runtime.ml` (via `make_config` helper — see W2-C)
- `bin/main.ml` (add `eval_limits = Expression.default_eval_limits`)
- `examples/basic_agent.ml` (same)
- Test files (handled in W2-D)

---

### W2-B: P1-1 — Expression evaluator accepts limits

**Depends on**: W2-A (eval_limits type exists in types.ml)

**Files**: `lib/core/expression.ml`, `lib/core/expression.mli`

**expression.ml**:
1. Replace `let max_depth = 10` / `let max_node_visits = 1000` with:
```ocaml
type eval_limits = Types.eval_limits = {
  max_depth : int;
  max_node_visits : int;
}

let default_eval_limits : eval_limits =
  { max_depth = 10; max_node_visits = 1000 }
```
2. Thread `limits` through: `check_limit`, `eval`, `evaluate`, `evaluate_to_bool`
3. Every `eval ctx ... (depth + 1)` → `eval ctx limits ... (depth + 1)`
4. `evaluate`/`evaluate_to_bool` get `?(limits = default_eval_limits)` param

**expression.mli**: Add `eval_limits` type, `default_eval_limits`, update `evaluate`/`evaluate_to_bool` signatures.

---

### W2-C: P0-2 — Human_approval respects timeout + runtime updates

**Depends on**: W2-B (eval_limits in expression)

**Files**:
- `lib/core/workflow_engine.ml` + `.mli`
- `lib/core/runtime.ml` + `.mli`
- `bin/main.ml`
- `examples/basic_agent.ml`

#### workflow_engine.ml
1. Add `eval_limits : Types.eval_limits` field to `exec_context`
2. Add `timeout : float` + `suspended_at : float` fields to `Workflow_suspended` exception
3. Add `check_approval_timeout` function
4. Line 98: Change `timeout = _` to `timeout`; add `suspended_at = Unix.gettimeofday ()` to raised exception
5. Line 87: `Expression.evaluate_to_bool ctx.variables condition` → add `~limits:ctx.eval_limits`

#### workflow_engine.mli
Add `eval_limits` to `exec_context`, `timeout`/`suspended_at` to `Workflow_suspended`, declare `check_approval_timeout`.

#### runtime.ml
1. Add `approval_deadlines : (Workflow_run_id.t, float * float) protected_hashtbl` to `runtime`
2. Add `make_config` builder function
3. Update `submit_workflow`: capture `timeout`/`suspended_at` from Workflow_suspended, store in `approval_deadlines`, add `eval_limits` to exec_context
4. Add `resume_after_timeout_check` helper
5. Update `resume_workflow`: check approval timeout via `check_approval_timeout` before resuming
6. Add `eval_limits` to all exec_context constructions
7. Update `create` to init `approval_deadlines`
8. Add `config rt` accessor
9. Improve `close` with shutdown config usage + doc comment

#### runtime.mli
Add: `make_config`, `config`

#### bin/main.ml (~line 145)
Add `eval_limits = Expression.default_eval_limits` to `make_runtime_config`

#### examples/basic_agent.ml (~line 10)
Add `eval_limits = Expression.default_eval_limits` to config literal

---

### W2-D: Test updates for test_integration.ml

**CRITICAL**: Only APPEND to this file. Do NOT modify lines 617-732 (P2 sanitize tests) or 734-741 (runner).

**Changes to existing test code** (insert `eval_limits` field):
- ~9 exec_context literals need `eval_limits = Expression.default_eval_limits` added
- 1 Workflow_suspended pattern match needs `; _` wildcard added (line ~359)

**New test suites to APPEND before line 734**:

1. **In `workflow_persistence_suite`** — add 3 tests:
   - "Human_approval carries timeout and suspended_at"
   - "approval timeout check rejects expired"
   - "approval timeout check accepts within window"
   - "approval timeout check rejects at boundary+"

2. **In `middleware_suite`** — add 8 tests:
   - "validation strict: on_after_tool returns Error for invalid args"
   - "validation lenient: on_before_tool repairs invalid args"
   - "validation lenient: on_after_tool allows repaired args through"
   - "validation on_after_llm repairs empty response"
   - "validation on_after_llm repairs empty tool_calls response"
   - "validation on_after_llm passes valid response through"
   - "retry with custom config: max_attempts=1 stops after one"
   - "retry with default config allows 3 attempts"
   - "rate_limit with custom config: max_requests=2 blocks after 2"

3. **New `cancellation_suite`** — 3 tests:
   - "with_timeout returns Ok when work finishes in time"
   - "with_timeout returns Timeout when work takes too long"
   - "with_timeout returns Ok for instant work"

4. **New `runtime_suite`** — 3 tests:
   - "make_config with defaults"
   - "make_config with overrides"
   - "create with non-default config"

5. **Update runner** (lines 734-741) to include `cancellation_suite; runtime_suite`

### W2-E: test_expression.ml + test_types.ml updates

**test_expression.ml** — ADD 4 tests to existing `limit_suite`:
- "custom depth limit (2) rejects nesting of 3"
- "custom depth limit (2) accepts nesting of 2"
- "custom node visit limit (5) rejects large tree"
- "default limits still work for backward compat"

**test_types.ml** — NEW test suite for task_completion_of_yojson Result type:
- Tests that valid JSON returns `Ok`
- Tests that invalid JSON returns `Error "..."` instead of raising
- Tests edge cases (missing fields, wrong types)

---

## Wave 3 — Verification + Commits

### Step 1: Build
```bash
PATH="/root/dev/PAR/_opam/bin:$PATH" dune build
```

### Step 2: Test
```bash
PATH="/root/dev/PAR/_opam/bin:$PATH" dune runtest
```
Expected: 230+ tests (214 current + ~16 new)

### Step 3: Commit Sequence
```bash
# P2 first
git add -A && git commit -m "feat(middleware): P2 sanitize_tool_output + http_client + builtin_tools tests"

# P0/P1 in dependency order
git add lib/core/cancellation.ml
git commit -m "fix(cancellation): P0-1 with_timeout now respects seconds param"

git add lib/core/types.ml lib/core/types.mli
git commit -m "fix(types): P0-3 task_completion_of_yojson returns Result + P1-1 add eval_limits type"

git add lib/persistence/sqlite_persistence.ml lib/persistence/postgres_persistence.ml lib/ffi/par_capi.ml
git commit -m "fix(persistence,ffi): P0-4 remove ignore() from cleanup paths, log errors"

git add lib/core/expression.ml lib/core/expression.mli
git commit -m "refactor(expression): P1-1 parameterize eval limits from config"

git add lib/core/workflow_engine.ml lib/core/workflow_engine.mli lib/core/runtime.ml lib/core/runtime.mli
git commit -m "fix(workflow): P0-2 human_approval respects timeout + approval_deadlines tracking"

git add lib/middleware/retry.ml lib/middleware/rate_limit.ml
git commit -m "refactor(middleware): P1-3 parameterize retry/rate_limit with config records"

git add lib/middleware/validation.ml
git commit -m "fix(validation): P1-4 proper error handling, repair instead of swallow"

git add bin/main.ml examples/basic_agent.ml test/test_integration.ml test/test_expression.ml
git commit -m "test: add P0/P1 tests, update runtime_config sites for eval_limits"
```

---

## Ultrawork Execution Summary

```
Phase 1 (5 agents parallel):
  [W1-A] P0-1: cancellation.ml              ← independent
  [W1-B] P0-4: sqlite + postgres + par_capi  ← independent
  [W1-C] P0-3: types.ml task_completion      ← independent
  [W1-D] P1-3: retry.ml + rate_limit.ml      ← independent
  [W1-E] P1-4: validation.ml                 ← independent

Phase 2 (sequential):
  [W2-A] P1-1 prep: eval_limits in types.ml/types.mli

Phase 3 (2 agents parallel):
  [W2-B] P1-1: expression.ml limits threading
  [W2-C] P0-3 callers: fix task_completion_of_yojson call sites

Phase 4 (1 agent):
  [W2-D] P0-2: workflow_engine + runtime + bin + examples + test_integration

Phase 5 (1 agent):
  [W2-E] test_expression.ml + test_types.ml updates

Phase 6 (sequential verification):
  dune build && dune runtest
  Atomic commits in dependency order
```

## Verification Checklist

- [ ] P0-1: `Cancellation.with_timeout 0.1 token slow_work` → `Error `Timeout`
- [ ] P0-2: `Workflow_suspended` carries `timeout` + `suspended_at`; `check_approval_timeout` works
- [ ] P0-3: `task_completion_of_yojson \`Null` → `Error "..."` (no failwith)
- [ ] P0-4: No `ignore()` on cleanup; errors logged instead
- [ ] P1-1: `Expression.evaluate ~limits:{max_depth=2; max_node_visits=1000}` rejects depth-3
- [ ] P1-3: `Retry.retry ~config:{max_attempts=1;...} ()` stops after 1
- [ ] P1-3: `Rate_limit.rate_limit ~config:{max_requests=2; window=1.0} ()` blocks 3rd
- [ ] P1-4: `Validation.validation ~strict:true ()` on_after_llm repairs empty response
- [ ] P1-4: `Validation.validation ~strict:false ()` lenient passes repaired args through
- [ ] All existing 214 tests + P2 sanitize tests still pass
- [ ] `dune build` clean with 0 errors
