val bench_type_safety : unit -> Benchmark_types.benchmark_result
val bench_tool_accuracy : unit -> Benchmark_types.benchmark_result
val bench_state_soundness : unit -> Benchmark_types.benchmark_result
val bench_middleware_composition : unit -> Benchmark_types.benchmark_result
val run_all : unit -> Benchmark_types.benchmark_suite
val run_benchmark :
  string ->
  string ->
  Benchmark_types.measurement list ->
  passed:bool ->
  Benchmark_types.benchmark_result
