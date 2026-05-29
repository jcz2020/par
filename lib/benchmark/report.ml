open Benchmark_types

let to_table suite =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf (Printf.sprintf "=== %s ===\n" suite.suite_name);
  List.iter (fun r ->
    Buffer.add_string buf
      (Printf.sprintf "\n[%s] %s (%s)\n" r.benchmark_id r.description
         (if r.passed then "PASS" else "FAIL"));
    List.iter (fun m ->
      Buffer.add_string buf
        (Printf.sprintf "  %-30s %8.2f %s\n" m.name m.value m.unit_))
      r.measurements)
    suite.results;
  Buffer.contents buf

let to_latex suite =
  let buf = Buffer.create 2048 in
  Buffer.add_string buf "\\begin{table}[h]\n\\centering\n";
  Buffer.add_string buf "\\begin{tabular}{llrl}\n\\toprule\n";
  Buffer.add_string buf "Category & Metric & Value & Unit \\\\\n\\midrule\n";
  List.iter (fun r ->
    List.iter (fun m ->
      Buffer.add_string buf
        (Printf.sprintf "%s & %s & %.2f & %s \\\\\n" m.category m.name
           m.value m.unit_))
      r.measurements)
    suite.results;
  Buffer.add_string buf "\\bottomrule\n\\end{tabular}\n";
  Buffer.add_string buf (Printf.sprintf "\\caption{%s}\n" suite.suite_name);
  Buffer.add_string buf "\\end{table}\n";
  Buffer.contents buf

let to_markdown suite =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf (Printf.sprintf "## %s\n\n" suite.suite_name);
  Buffer.add_string buf "| Category | Metric | Value | Unit |\n|---|---|---|---|\n";
  List.iter (fun r ->
    Buffer.add_string buf
      (Printf.sprintf "| **%s** | | | |\n" r.benchmark_id);
    List.iter (fun m ->
      Buffer.add_string buf
        (Printf.sprintf "| %s | %s | %.2f | %s |\n" m.category m.name
           m.value m.unit_))
      r.measurements)
    suite.results;
  Buffer.contents buf
