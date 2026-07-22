"""Low-level ctypes FFI declarations for par_capi.so.

This is the ONLY module that touches ctypes directly.
All other modules import from here.
"""
import ctypes
import ctypes.util
import os
import sys
from pathlib import Path
from typing import Optional


def _find_library() -> str:
    """Find the par_capi.so shared library."""
    # 1. PAR_RUNTIME_LIB env var
    env = os.environ.get("PAR_RUNTIME_LIB")
    if env and Path(env).exists():
        return env
    # 2. Relative to this package
    pkg_dir = Path(__file__).resolve().parent
    project_root = pkg_dir.parent.parent.parent
    candidates = [
        pkg_dir / "lib" / "par_capi.so",
        project_root / "_build" / "default" / "lib" / "ffi" / "par_capi.so",
    ]
    for c in candidates:
        if c.exists():
            return str(c)
    # 3. System library path
    return "par_capi.so"


def _vec_extension_path() -> Optional[str]:
    """Locate the sqlite-vec extension bundled with par-runtime.

    Returns the absolute path of vec0.so / vec0.dylib next to par_capi.so
    in the wheel, or None if not found. The Python binding passes this to
    par_set_vec_extension_path() before par_init() so the OCaml runtime
    can sqlite3_load_extension() from the correct location regardless of
    the user's current working directory.
    """
    env = os.environ.get("PAR_VEC_PATH")
    if env and Path(env).exists():
        return env
    pkg_dir = Path(__file__).resolve().parent
    for name in ("vec0.so", "vec0.dylib"):
        candidate = pkg_dir / "lib" / name
        if candidate.exists():
            return str(candidate)
    project_root = pkg_dir.parent.parent.parent
    for sub in ("linux-x86_64/vec0.so", "macos-aarch64/vec0.dylib"):
        candidate = project_root / "vendor" / "sqlite-vec" / sub
        if candidate.exists():
            return str(candidate)
    return None


_lib = ctypes.CDLL(_find_library())

# --- Declare function signatures ---

# par_runtime_t* par_init(const char* config_json);
_lib.par_init.argtypes = [ctypes.c_char_p]
_lib.par_init.restype = ctypes.c_void_p

# void par_shutdown(par_runtime_t* rt);
_lib.par_shutdown.argtypes = [ctypes.c_void_p]
_lib.par_shutdown.restype = None

# int par_register_tool(par_runtime_t* rt, const char* name,
#                       const char* description, const char* input_schema);
_lib.par_register_tool.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p
]
_lib.par_register_tool.restype = ctypes.c_int

# int par_register_tool_with_handler(par_runtime_t* rt, const char* name,
#                                     const char* description, const char* input_schema,
#                                     int handler_id);
_lib.par_register_tool_with_handler.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int
]
_lib.par_register_tool_with_handler.restype = ctypes.c_int

# void par_store_python_handler(int handler_id, par_tool_callback fn);
# par_tool_callback = char* (*)(int handler_id, const char* input_json)
_PYTHON_TOOL_CALLBACK = ctypes.CFUNCTYPE(ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p)
_lib.par_store_python_handler.argtypes = [ctypes.c_int, _PYTHON_TOOL_CALLBACK]
_lib.par_store_python_handler.restype = None

# char* par_invoke_stream(par_runtime_t* rt, const char* agent_id,
#                         const char* message,
#                         par_chunk_callback cb, void* user_data);
# par_chunk_callback = void (*)(const char* json_chunk, void* user_data)
# The callback receives a JSON-encoded llm_response_chunk; the bytes are
# owned by the OCaml runtime for the duration of the call only, so the
# callback MUST copy/decode before returning. user_data is opaque to C;
# the Python binding always passes NULL because the ctypes closure already
# captures state.
# Returns: final result JSON string (caller MUST free()) or NULL on error.
_STREAM_CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_void_p)
_lib.par_invoke_stream.argtypes = [
    ctypes.c_void_p,    # rt handle
    ctypes.c_char_p,    # agent_id
    ctypes.c_char_p,    # message
    _STREAM_CALLBACK,   # chunk callback (closure captures queue)
    ctypes.c_void_p,    # user_data (always NULL — closure captures state)
]
_lib.par_invoke_stream.restype = ctypes.c_void_p

# void par_cancel_stream(par_runtime_t* rt);
# Cancel an in-flight par_invoke_stream. Safe to call from any thread
# (no ocaml_lock acquired — the in-flight stream holds it). Sets a
# process-global atomic flag checked by the on_chunk callback at the
# next chunk boundary; cancel takes effect at the next chunk (50-300ms).
_lib.par_cancel_stream.argtypes = [ctypes.c_void_p]
_lib.par_cancel_stream.restype = None

# v0.7.10+: per-stream-handle async API. Replaces the daemon-thread model.
# par_stream_start returns an opaque handle (heap pointer); par_stream_poll
# is pure C and never touches the OCaml runtime — that's the whole point.
_PAR_STREAM_DONE = ctypes.c_void_p(1)  # sentinel returned by poll on completion

_lib.par_stream_start.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
_lib.par_stream_start.restype = ctypes.c_void_p
_lib.par_stream_poll.argtypes = [ctypes.c_void_p, ctypes.c_int]
_lib.par_stream_poll.restype = ctypes.c_void_p
_lib.par_stream_cancel.argtypes = [ctypes.c_void_p]
_lib.par_stream_cancel.restype = None
_lib.par_stream_take_final.argtypes = [ctypes.c_void_p]
_lib.par_stream_take_final.restype = ctypes.c_void_p
_lib.par_stream_free.argtypes = [ctypes.c_void_p]
_lib.par_stream_free.restype = None

# int par_register_agent(par_runtime_t* rt, const char* config_json);
_lib.par_register_agent.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_register_agent.restype = ctypes.c_int

# int par_register_skill(par_runtime_t* rt, const char* json);
_lib.par_register_skill.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_register_skill.restype = ctypes.c_int

# char* par_list_skills(par_runtime_t* rt);
_lib.par_list_skills.argtypes = [ctypes.c_void_p]
_lib.par_list_skills.restype = ctypes.c_void_p

# v0.5.4 PAR-tiu: LLM provider registry surface
# char* par_list_llm_providers(par_runtime_t* rt);
_lib.par_list_llm_providers.argtypes = [ctypes.c_void_p]
_lib.par_list_llm_providers.restype = ctypes.c_void_p
# int par_set_default_llm_provider(par_runtime_t* rt, const char* provider_id);
_lib.par_set_default_llm_provider.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_set_default_llm_provider.restype = ctypes.c_int

# v0.5.4 PAR-mkm: Session resume surface
# void par_set_session_id(par_runtime_t* rt, const char* session_id);
_lib.par_set_session_id.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_set_session_id.restype = None
# char* par_get_session_id(par_runtime_t* rt);
_lib.par_get_session_id.argtypes = [ctypes.c_void_p]
_lib.par_get_session_id.restype = ctypes.c_void_p
# int par_save_conversation(par_runtime_t* rt);
_lib.par_save_conversation.argtypes = [ctypes.c_void_p]
_lib.par_save_conversation.restype = ctypes.c_int
# int par_load_conversation(par_runtime_t* rt, const char* session_id);
_lib.par_load_conversation.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_load_conversation.restype = ctypes.c_int

# char* par_invoke(par_runtime_t* rt, const char* agent_id, const char* message);
# Caller MUST free() the returned string — returns c_void_p, not c_char_p
_lib.par_invoke.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
_lib.par_invoke.restype = ctypes.c_void_p

_lib.par_invoke_ext.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
_lib.par_invoke_ext.restype = ctypes.c_void_p

# char* par_generate(par_runtime_t* rt, const char* agent_id, const char* message);
# Caller MUST free() the returned string — same memory model as par_invoke.
_lib.par_generate.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
_lib.par_generate.restype = ctypes.c_void_p

_lib.par_generate_ext.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
_lib.par_generate_ext.restype = ctypes.c_void_p

# char* par_embed(par_runtime_t* rt, const char* messages_json);
_lib.par_embed.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_embed.restype = ctypes.c_void_p

# int par_add_documents(par_runtime_t* rt, const char* docs_json);
_lib.par_add_documents.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_add_documents.restype = ctypes.c_int

# char* par_load_document(par_runtime_t* rt, const char* path);
_lib.par_load_document.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_load_document.restype = ctypes.c_void_p

# char* par_load_directory(par_runtime_t* rt, const char* path, const char* loaders_json);
_lib.par_load_directory.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
_lib.par_load_directory.restype = ctypes.c_void_p

# char* par_invoke_with_rag(par_runtime_t* rt, const char* agent_id,
#                           const char* message, const char* k_str);
_lib.par_invoke_with_rag.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                     ctypes.c_char_p, ctypes.c_char_p]
_lib.par_invoke_with_rag.restype = ctypes.c_void_p

# char* par_invoke_structured(par_runtime_t* rt, const char* agent_id,
#                              const char* message, const char* schema_json);
_lib.par_invoke_structured.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                       ctypes.c_char_p, ctypes.c_char_p]
_lib.par_invoke_structured.restype = ctypes.c_void_p

# char* par_submit_workflow(par_runtime_t* rt, const char* workflow_json);
_lib.par_submit_workflow.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_submit_workflow.restype = ctypes.c_void_p

# int par_approve_workflow(par_runtime_t* rt, const char* run_id, const char* approver);
_lib.par_approve_workflow.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
_lib.par_approve_workflow.restype = ctypes.c_int

# char* par_resume_workflow(par_runtime_t* rt, const char* run_id);
_lib.par_resume_workflow.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_resume_workflow.restype = ctypes.c_void_p

# char* par_health(par_runtime_t* rt);
_lib.par_health.argtypes = [ctypes.c_void_p]
_lib.par_health.restype = ctypes.c_void_p

# char* par_metrics(par_runtime_t* rt);
_lib.par_metrics.argtypes = [ctypes.c_void_p]
_lib.par_metrics.restype = ctypes.c_void_p

# int par_steer(par_runtime_t* rt, const char* message);
_lib.par_steer.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_steer.restype = ctypes.c_int

# int par_follow_up(par_runtime_t* rt, const char* message);
_lib.par_follow_up.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_follow_up.restype = ctypes.c_int

# char* par_mcp_server(par_runtime_t* rt, const char* server_id);
_lib.par_mcp_server.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_mcp_server.restype = ctypes.c_void_p

# char* par_mcp_list_tools(par_runtime_t* rt, const char* server_id);
_lib.par_mcp_list_tools.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_mcp_list_tools.restype = ctypes.c_void_p

# char* par_workflow_status(par_runtime_t* rt, const char* run_id);
_lib.par_workflow_status.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_workflow_status.restype = ctypes.c_void_p

# int par_workflow_cancel(par_runtime_t* rt, const char* run_id);
_lib.par_workflow_cancel.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_workflow_cancel.restype = ctypes.c_int

# int par_event_subscribe(par_runtime_t* rt, void* callback);
_lib.par_event_subscribe.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
_lib.par_event_subscribe.restype = ctypes.c_int

# char* par_version(void);
_lib.par_version.argtypes = []
_lib.par_version.restype = ctypes.c_void_p

# int par_set_request_timeout(double seconds);
_lib.par_set_request_timeout.argtypes = [ctypes.c_double]
_lib.par_set_request_timeout.restype = ctypes.c_int

# int par_set_vec_extension_path(const char* path);
_lib.par_set_vec_extension_path.argtypes = [ctypes.c_char_p]
_lib.par_set_vec_extension_path.restype = ctypes.c_int

# --- Helper: libc free() for strings returned by C ---
if sys.platform == "darwin":
    _libc = ctypes.CDLL("libc.dylib")
else:
    _libc_name = ctypes.util.find_library("c") or "libc.so.6"
    _libc = ctypes.CDLL(_libc_name)

_free = _libc.free
_free.argtypes = [ctypes.c_void_p]
_free.restype = None


def _c_str(s: str) -> bytes:
    """Encode a Python string as UTF-8 bytes for ctypes."""
    return s.encode("utf-8")


def _py_str(ptr: ctypes.c_void_p) -> str:
    """Extract a Python string from a C char* and free the C memory."""
    if not ptr:
        return ""
    try:
        result = ctypes.cast(ptr, ctypes.c_char_p).value
        if result is None:
            return ""
        return result.decode("utf-8")
    finally:
        _free(ptr)


# Set the vec0.{so,dylib} absolute path before the first par_init.
# This is required because Sys.executable_name inside OCaml points at
# the host binary (python3), not at par_capi.so, so the runtime cannot
# locate the extension on its own when the wheel is installed in
# site-packages/ or anywhere outside the project tree.
_vec_path = _vec_extension_path()
if _vec_path is not None:
    _lib.par_set_vec_extension_path(_c_str(_vec_path))
