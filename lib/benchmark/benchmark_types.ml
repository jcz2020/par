(* Benchmark type definitions for paper §6 experiments *)

type metric_name = string

type measurement = {
  name : metric_name;
  value : float;
  unit_ : string;  (** "count" | "rate" | "ratio" | "ms" *)
  category : string;  (** "type_safety" | "tool_accuracy" | "state_machine" | "middleware" *)
}

type benchmark_result = {
  benchmark_id : string;
  description : string;
  measurements : measurement list;
  passed : bool;
  timestamp : float;
}

type benchmark_suite = {
  suite_name : string;
  results : benchmark_result list;
}

(** Helper constructors *)

let measurement ~name ~value ~unit_ ~category =
  { name; value; unit_; category }

let result ~id ~desc ~measurements ~passed =
  {
    benchmark_id = id;
    description = desc;
    measurements;
    passed;
    timestamp = Unix.gettimeofday ();
  }

let suite ~name results =
  { suite_name = name; results }
