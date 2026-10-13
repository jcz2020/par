let name = "tool_search"

let descriptor : Types.tool_descriptor = {
  name;
  description = "Search available tools by keyword. Returns matching tool \
                 descriptors and makes them available for invocation in this \
                 session.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("query", `Assoc [
        ("type", `String "string");
        ("description", `String "Search query (keywords)")
      ]);
      ("category", `Assoc [
        ("type", `String "string");
        ("description", `String "Optional category filter")
      ]);
    ]);
    ("required", `List [`String "query"]);
  ];
  output_schema = None;
  permission = Types.Allow;
  timeout = None;
  concurrency_limit = None;
  on_update = None;
  cache_control = None;
}

let lowercase_contains ~needle haystack =
  let needle = String.lowercase_ascii needle in
  let haystack = String.lowercase_ascii haystack in
  try ignore (Str.search_forward (Str.regexp_string needle) haystack 0); true
  with Not_found -> false

let score_candidate query_words (d : Types.tool_descriptor) =
  let name_l = String.lowercase_ascii d.Types.name in
  let desc_l = String.lowercase_ascii d.Types.description in
  List.fold_left (fun acc word ->
    let name_hit = if lowercase_contains ~needle:word name_l then 4 else 0 in
    let desc_hit = if lowercase_contains ~needle:word desc_l then 1 else 0 in
    acc + name_hit + desc_hit
  ) 0 query_words

let matches_category category (d : Types.tool_descriptor) =
  match category with
  | None -> true
  | Some cat ->
    lowercase_contains ~needle:cat d.Types.name ||
    lowercase_contains ~needle:cat d.Types.description

let search ~query ~category (candidates : Types.tool_descriptor list) : Types.tool_descriptor list =
  let filtered = List.filter (matches_category category) candidates in
  let query_words =
    String.split_on_char ' ' (String.lowercase_ascii query)
    |> List.filter (fun w -> String.length w > 0)
  in
  let scored : (Types.tool_descriptor * int) list =
    if query_words = [] then
      List.map (fun (d : Types.tool_descriptor) -> (d, 0)) filtered
    else
      List.map (fun (d : Types.tool_descriptor) ->
        (d, score_candidate query_words d)
      ) filtered
      |> List.filter (fun (_, score) -> score > 0)
  in
  let sorted =
    List.sort (fun ((a : Types.tool_descriptor), (sa : int)) ((b : Types.tool_descriptor), (sb : int)) ->
      let c = Int.compare sb sa in
      if c <> 0 then c else String.compare a.name b.name
    ) scored
  in
  List.map fst sorted

let take_n n l =
  let rec go acc n = function
    | _ when n <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: rest -> go (x :: acc) (n - 1) rest
  in
  go [] n l

let make_handler (registry : Tool_registry.t) : Tool_registry.handler_fn =
  fun input _token ->
    let query = match Yojson.Safe.Util.member "query" input with
      | `String s -> s
      | _ -> ""
    in
    let category = match Yojson.Safe.Util.member "category" input with
      | `String s -> Some s
      | _ -> None
    in
    let candidates = Tool_registry.searchable_descriptors registry in
    let all_matches = search ~query ~category candidates in
    let top = take_n 10 all_matches in
    Invoke_context.promote_tools top;
    let matches_json = `List (List.map (fun (d : Types.tool_descriptor) ->
      `Assoc [
        ("name", `String d.Types.name);
        ("description", `String d.Types.description);
        ("input_schema", d.Types.input_schema);
      ]
    ) top) in
    Types.Success (`Assoc [
      ("matches", matches_json);
      ("count", `Int (List.length top));
      ("promoted", `Int (List.length top));
    ])
