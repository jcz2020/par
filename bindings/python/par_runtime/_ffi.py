"""Low-level ctypes FFI declarations for par_capi.so.

This is the ONLY module that touches ctypes directly.
All other modules import from here.
"""
import ctypes
import ctypes.util
import os
import sys
from pathlib import Path


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

# int par_register_agent(par_runtime_t* rt, const char* config_json);
_lib.par_register_agent.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.par_register_agent.restype = ctypes.c_int

# char* par_invoke(par_runtime_t* rt, const char* agent_id, const char* message);
# Caller MUST free() the returned string — returns c_void_p, not c_char_p
_lib.par_invoke.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
_lib.par_invoke.restype = ctypes.c_void_p

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
