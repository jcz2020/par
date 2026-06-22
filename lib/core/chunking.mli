(** Text chunking — Phase B.3 of v0.5.1 RAG foundation.

    Three splitter strategies for dividing text into processing chunks,
    suitable for embedding-based retrieval (RAG). All splitters are pure:
    no I/O, no provider coupling, no tokenizer dependency.

    For accurate token counts, the caller should pre-tokenize with the
    provider's tokenizer before calling [chunk_by_tokens]; see its
    documentation for the approximation used. *)


type chunk = {
  text : string;
  start_pos : int;  (** offset of the first character in the original text *)
  end_pos : int;    (** offset one past the last character (half-open) *)
}


(** [chunk_by_chars ~text ~max_size ~overlap] divides [text] into chunks of
    at most [max_size] characters, with [overlap] characters shared between
    consecutive chunks.

    The stride between chunk starts is [max_size - overlap]. Each chunk's
    [start_pos] and [end_pos] refer to the substring's position in [text].

    @param max_size  must be > 0
    @param overlap   must satisfy [0 <= overlap < max_size]
    @raise Invalid_argument if [max_size <= 0] or [overlap >= max_size] *)
val chunk_by_chars :
  text:string -> max_size:int -> overlap:int -> chunk list

(** [chunk_by_tokens ~text ~max_tokens ~overlap] divides [text] into chunks
    of at most [max_tokens] whitespace-separated words, with [overlap] tokens
    shared between consecutive chunks.

    Approximate token-based chunking using whitespace splitting: one
    whitespace-separated word is treated as one token. For accurate token
    counts, the caller should pre-tokenize with the provider's tokenizer
    and pass the result to [chunk_by_chars] on the concatenated tokens.

    @param max_tokens  must be > 0
    @param overlap     must satisfy [0 <= overlap < max_tokens]
    @raise Invalid_argument if [max_tokens <= 0] or [overlap >= max_tokens] *)
val chunk_by_tokens :
  text:string -> max_tokens:int -> overlap:int -> chunk list

(** [chunk_recursive ~text ?separators ~max_size ~overlap] divides [text]
    using the LangChain RecursiveCharacterTextSplitter algorithm: it tries
    each separator in order, falling through to finer separators when a
    piece exceeds [max_size].

    Default separators are [["\n\n"; "\n"; " "; ""]] — paragraph breaks,
    line breaks, spaces, then individual characters. This is the LangChain
    default.

    The caller must specify [max_size] and [overlap]; this module does NOT
    inherit LangChain's [chunk_size=4000, chunk_overlap=200] defaults.

    @param separators  defaults to [["\n\n"; "\n"; " "; ""]]
    @param max_size    must be > 0
    @param overlap     must satisfy [0 <= overlap < max_size]
    @raise Invalid_argument if [max_size <= 0] or [overlap >= max_size] *)
val chunk_recursive :
  text:string ->
  ?separators:string list ->
  max_size:int ->
  overlap:int ->
  chunk list
