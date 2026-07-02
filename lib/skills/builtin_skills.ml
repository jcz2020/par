open Types

let builtin_skills : skill_descriptor list = [
  {
    schema_version = 1;
    id = "code-reviewer";
    name = "Code Reviewer";
    description = "Review code for bugs, security issues, and style problems. Use when the user asks to review, audit, or check code quality.";
    system_prompt_override = Some (Stable_prompt "You are a meticulous code reviewer. Analyze code for correctness, security, performance, and style. Provide specific, actionable feedback with file:line references.");
    tool_filter = Only ["read"; "grep"; "find"];
    trigger = Keyword { keywords = ["review"; "audit"; "code review"]; llm_confirm = true };
    expected_output = None;
    body_path = "";
  };
  {
    schema_version = 1;
    id = "summarizer";
    name = "Summarizer";
    description = "Summarize long text, documents, or conversations into concise key points. Use when the user asks for a summary or TL;DR.";
    system_prompt_override = Some (Stable_prompt "You are an expert summarizer. Distill information into clear, concise summaries. Preserve key facts, drop redundancy. Use bullet points for readability.");
    tool_filter = All_tools;
    trigger = Auto;
    expected_output = None;
    body_path = "";
  };
  {
    schema_version = 1;
    id = "translator";
    name = "Translator";
    description = "Translate text between languages. Use when the user asks to translate or asks about translation.";
    system_prompt_override = Some (Stable_prompt "You are a professional translator. Translate accurately while preserving tone and context. If the target language is ambiguous, ask for clarification.");
    tool_filter = All_tools;
    trigger = Keyword { keywords = ["translate"; "翻译"; "translation"]; llm_confirm = true };
    expected_output = None;
    body_path = "";
  };
  {
    schema_version = 1;
    id = "rag-assistant";
    name = "RAG Assistant";
    description = "Answer questions using retrieved document context. Use when the user asks about indexed documents or wants knowledge-grounded answers.";
    system_prompt_override = Some (Stable_prompt "You are a RAG assistant. Answer questions using the provided retrieved context. If the context doesn't contain the answer, say so clearly. Always cite which document the information came from.");
    tool_filter = All_tools;
    trigger = Auto;
    expected_output = None;
    body_path = "";
  };
]
