open Types

let content_of_string s =
  if s = "" then []
  else [Text_block { text = s; cache_control = None }]

let string_of_content blocks =
  blocks
  |> List.filter_map (function
       | Text_block { text; _ } -> Some text
       | Tool_result_block { content; _ } -> Some content
       | _ -> None)
  |> String.concat ""

let text_of_message msg =
  string_of_content msg.content_blocks

let content_opt msg =
  let s = string_of_content msg.content_blocks in
  if s = "" then None else Some s
