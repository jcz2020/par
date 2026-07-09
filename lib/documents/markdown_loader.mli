(** Markdown loader (.md).

    Parses markdown via [Omd.of_string] and walks the AST to extract plain
    text (headings, paragraphs, code blocks, lists). YAML frontmatter
    (between [---] delimiters at file start) is parsed via [Yaml.of_string]
    and merged into the [Document.t] metadata alongside standard fields
    (file_path, file_name, file_size, file_type="text/markdown"). *)

val make : Workspace.workspace -> string ->
  (unit -> Document.t list, Document.load_error) result
