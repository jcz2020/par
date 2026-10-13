let estimate_tokens (descriptors : Types.tool_descriptor list) : int =
  List.fold_left (fun acc (d : Types.tool_descriptor) ->
    let name_chars = String.length d.name in
    let desc_chars = String.length d.description in
    let schema_chars = String.length (Yojson.Safe.to_string d.input_schema) in
    let est = max 1 ((name_chars + desc_chars + schema_chars + 3) / 4) in
    acc + est
  ) 0 descriptors
