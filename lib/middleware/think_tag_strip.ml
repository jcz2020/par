let create () : Types.middleware_hook = {
  Types.name = "think_tag_strip";
  on_before_llm = None;
  on_after_llm = Some (fun resp ->
    match resp.text with
    | Some text ->
      let stripped = Json_extract.strip_think_tags text in
      if stripped = text then None
      else Some { resp with Types.text = Some stripped }
    | None -> None
  );
  on_before_tool = None;
  on_after_tool = None;
  on_error = None;
}
