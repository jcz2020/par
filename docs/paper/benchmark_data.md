# P-A-R Benchmark Baseline Data

Generated: 2026-05-30
Commit: ba00f2c

## Test Results

| Suite | Tests | Time | Status |
|-------|-------|------|--------|
| Integration | 23 | 0.046s | ✅ All pass |
| Mock Provider | 13 | 0.007s | ✅ All pass |
| Benchmark | 16 | 0.011s | ✅ All pass |
| Core | 110 | 0.042s | ✅ All pass |
| SSE Stream | 1 | 1.381s | ✅ Pass (requires network) |
| **Total** | **163** | **~1.5s** | **All pass** |

## Benchmark Metrics (from lib/benchmark/harness.ml)

### Scenario §6a: Type Safety Ratio
- **Metric**: `type_safety_ratio`
- **Description**: Fraction of error classes caught at compile time vs runtime
- **Implementation**: 4 compile-time classes / 10 total = **0.40**
- **Compile-time errors** (4):
  1. Missing tool handler (exhaustiveness check on `handler_result`)
  2. Invalid tool permission (ADT pattern match)
  3. Wrong conversation role (ADT variant)
  4. Invalid state transition (`validate_transition` returns `Error`)
- **Runtime-only errors** (6):
  1. Malformed JSON args
  2. Network timeout
  3. LLM API error
  4. Workflow step not found
  5. Tool execution timeout
  6. Concurrency limit exceeded

### Scenario §6b: Tool Call Accuracy
- **Metric**: `tool_call_accuracy`
- **Description**: Correct tool dispatch rate across 100 scenarios
- **Implementation**: Uses mock provider with scripted tool call sequences
- **Expected value**: **1.0** (all tool calls dispatched to correct handlers)

### Scenario §6c: Transition Soundness
- **Metric**: `transition_soundness`
- **Description**: All valid transitions accepted, all invalid transitions rejected
- **Implementation**: Tests all 17 valid transitions from `state_machine.ml`
- **Expected values**:
  - `transition_soundness = 1.0` (all valid accepted)
  - `invalid_detection_rate = 1.0` (all invalid rejected)
  - `state_reachability = 1.0` (all 8 states reachable from Pending)
  - `max_path_length = 7` transitions (matches Property 4 in formalization)

### Scenario §6d: Middleware Composition Score
- **Metric**: `middleware_composition_score`
- **Description**: Fraction of middleware hooks active in composition
- **Implementation**: Tests all 6 built-in middleware × 5 hooks
- **Expected value**: **1.0** (all hooks active)
- **Additional verified properties**:
  - `test_identity_law = true` (identity middleware is neutral element)
  - `test_associativity_law = true` (composition is associative)

## State Machine Details

### 8 Task States
1. `Pending` — initial state
2. `Scheduled` — queued for execution
3. `Running` — currently executing
4. `Waiting_input` — awaiting user/tool input
5. `Suspended` — paused by workflow
6. `Completed` — terminal (success)
7. `Failed` — terminal (error)
8. `Cancelled` — terminal (user abort)

### 17 Valid Transitions
(From lib/core/state_machine.ml)
1. Pending → Scheduled
2. Scheduled → Running
3. Running → Completed
4. Running → Failed
5. Running → Waiting_input
6. Running → Suspended
7. Waiting_input → Running
8. Suspended → Running
9. Scheduled → Cancelled
10. Running → Cancelled
11. Waiting_input → Cancelled
12. Suspended → Cancelled
13. Pending → Cancelled
14. Running → Scheduled (re-queue)
15. Scheduled → Failed
16. Waiting_input → Failed
17. Suspended → Failed

### Terminal States (3)
- Completed, Failed, Cancelled

## Expression DSL

### 14 Expression Forms
(From lib/core/expression.ml)
1. Literal of json
2. Variable of string
3. Equals of expr * expr
4. Not_equals of expr * expr
5. Greater_than of expr * expr
6. Less_than of expr * expr
7. Greater_or_equal of expr * expr
8. Less_or_equal of expr * expr
9. And of expr * expr
10. Or of expr * expr
11. Not of expr
12. Contains of expr * expr
13. Is_empty of expr
14. Matches_regex of expr * expr

### Resource Bounds
- `max_depth = 10`
- `max_node_visits = 1000`
- All expression forms terminate within bounds (verified by tests)

## Middleware

### 6 Built-in Middleware
1. Logging — request/response logging
2. Retry — exponential/fixed/linear backoff
3. Rate_limit — configurable request rate
4. Timeout — execution time limit
5. Validation — input/output schema validation
6. Pii_mask — PII detection and masking

### 5 Hooks per Middleware
1. `on_before` — pre-execution
2. `on_after` — post-success
3. `on_error` — error handling
4. `on_tool_call` — tool dispatch
5. `on_tool_result` — tool response

## handler_result ADT (5 cases)

```ocaml
type handler_result =
  | Success of Yojson.Safe.t
  | Tool_not_found of string
  | Permission_denied of string
  | Execution_failed of string
  | Rate_limited of string
```

## Codebase Statistics
- ~6000+ lines of OCaml code
- 163 tests passing
- 13 builtin tools
- 6 middleware
- 2 LLM providers (OpenAI-compat + Anthropic-compat)
- 2 persistence backends (SQLite + PostgreSQL)
