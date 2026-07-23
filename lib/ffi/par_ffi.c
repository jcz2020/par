/* par_ffi.c — C implementation of the P-A-R FFI bridge.
   Bridges C callers to OCaml runtime via caml_callback.
   Thread-safe: ocaml_lock serializes callbacks.
   All OCaml value locals use CAMLparam/CAMLlocal macros to register
   as GC roots, preventing dangling pointers when caml_copy_string
   triggers a minor GC that moves previously allocated values. */

#include "par_ffi.h"
#include <caml/mlvalues.h>
#include <caml/callback.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/threads.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#ifdef _WIN32
#include <windows.h>
#include <intrin.h>
#else
#include <pthread.h>
#include <errno.h>
#endif

#ifdef _WIN32
/* eio_windows C stubs: the eio_windows opam package's C stubs are not
   properly linked on MinGW Cygwin (the .o file is missing from the
   installation). Provide implementations here so the final DLL link
   succeeds. Uses synchronous ReadFile/WriteFile (not overlapped I/O). */
CAMLprim value eio_windows_cstruct_read(value v_fd, value v_ba, value v_ofs, value v_len) {
    CAMLparam4(v_fd, v_ba, v_ofs, v_len);
    HANDLE h = (HANDLE)(intptr_t)Long_val(v_fd);
    char *data = (char *)Caml_ba_data_val(v_ba) + Long_val(v_ofs);
    DWORD n = 0;
    BOOL ok = ReadFile(h, data, (DWORD)Long_val(v_len), &n, NULL);
    if (!ok) { CAMLreturn(Val_long(-1)); }
    CAMLreturn(Val_long(n));
}
CAMLprim value eio_windows_cstruct_write(value v_fd, value v_ba, value v_ofs, value v_len) {
    CAMLparam4(v_fd, v_ba, v_ofs, v_len);
    HANDLE h = (HANDLE)(intptr_t)Long_val(v_fd);
    char *data = (char *)Caml_ba_data_val(v_ba) + Long_val(v_ofs);
    DWORD n = 0;
    BOOL ok = WriteFile(h, data, (DWORD)Long_val(v_len), &n, NULL);
    if (!ok) { CAMLreturn(Val_long(-1)); }
    CAMLreturn(Val_long(n));
}
#endif

/* ---- Portable mutex abstraction ---- */
#ifdef _WIN32
typedef SRWLOCK par_mutex_t;
#define PAR_MUTEX_INIT SRWLOCK_INIT
#define PAR_MUTEX_LOCK(m)   AcquireSRWLockExclusive(&(m))
#define PAR_MUTEX_UNLOCK(m) ReleaseSRWLockExclusive(&(m))
#else
typedef pthread_mutex_t par_mutex_t;
#define PAR_MUTEX_INIT PTHREAD_MUTEX_INITIALIZER
#define PAR_MUTEX_LOCK(m)   pthread_mutex_lock(&(m))
#define PAR_MUTEX_UNLOCK(m) pthread_mutex_unlock(&(m))
#endif

/* ---- Portable atomic abstraction ---- */
#ifdef _WIN32
#define ATOMIC_LOAD_ACQUIRE(x)  ((int)_InterlockedCompareExchange((volatile LONG*)&(x), 0, 0))
#define ATOMIC_STORE_RELEASE(x, v) _InterlockedExchange((volatile LONG*)&(x), (LONG)(v))
#else
#define ATOMIC_LOAD_ACQUIRE(x)  __atomic_load_n(&(x), __ATOMIC_ACQUIRE)
#define ATOMIC_STORE_RELEASE(x, v) __atomic_store_n(&(x), (v), __ATOMIC_RELEASE)
#endif

struct par_runtime {
    value _ocaml_value;
};

struct par_result {
    value _ocaml_value;
};

#ifdef _WIN32
static wchar_t *caml_argv[] = { L"par_ffi", NULL };
#else
static char *caml_argv[] = { "par_ffi", NULL };
#endif
static int ocaml_initialized = 0;
static par_mutex_t ocaml_lock = PAR_MUTEX_INIT;

#define MAX_PYTHON_HANDLERS 256
static par_tool_callback python_handler_table[MAX_PYTHON_HANDLERS];

static par_chunk_callback g_chunk_callback = NULL;
static void* g_chunk_user_data = NULL;
static volatile int g_stream_cancel_requested = 0;

void par_store_python_handler(int handler_id, par_tool_callback fn) {
    if (handler_id >= 0 && handler_id < MAX_PYTHON_HANDLERS) {
        python_handler_table[handler_id] = fn;
    }
}

value caml_invoke_python_handler(value v_handler_id, value v_input_json) {
    CAMLparam2(v_handler_id, v_input_json);
    CAMLlocal1(v_result);
    int handler_id = Int_val(v_handler_id);
    const char* input = String_val(v_input_json);
    if (handler_id >= 0 && handler_id < MAX_PYTHON_HANDLERS && python_handler_table[handler_id] != NULL) {
        char* result = python_handler_table[handler_id](handler_id, input);
        if (result != NULL) {
            v_result = caml_copy_string(result);
            CAMLreturn(v_result);
        }
    }
    v_result = caml_copy_string("");
    CAMLreturn(v_result);
}

value caml_dispatch_chunk_to_c(value v_json_chunk) {
    CAMLparam1(v_json_chunk);
    if (g_chunk_callback != NULL) {
        const char* json = String_val(v_json_chunk);
        g_chunk_callback(json, g_chunk_user_data);
    }
    CAMLreturn(Val_unit);
}

/* ---- v0.7.10 PAR-7be: per-stream-handle queue bridge ----
   Eliminates the Python daemon thread. par_stream_start enqueues work from
   the Python main thread (registered, safe); par_stream_poll is pure C
   (pthread_cond_timedwait), holds NO OCaml domain slot. Chunks flow:
   OCaml work_loop D1 → caml_dispatch_chunk_to_c_with_handle → C queue →
   par_stream_poll wakes via condvar. See .sisyphus/plans/v0.7.10-PLAN.md. */

typedef struct chunk_node {
    char*              json;
    struct chunk_node* next;
} chunk_node_t;

#define PAR_STREAM_RUNNING  0
#define PAR_STREAM_CANCEL   1
#define PAR_STREAM_DONE_OK  2
#define PAR_STREAM_DONE_ERR 3

typedef struct par_stream_handle {
    par_runtime_t*     rt;
    chunk_node_t*      q_head;
    chunk_node_t*      q_tail;
    par_mutex_t        q_mutex;
#ifndef _WIN32
    pthread_cond_t     q_cond;
#else
    CONDITION_VARIABLE q_cond;
#endif
    volatile int       state;
    char*              final_json;
} par_stream_handle_t;

/* Single-entry TLS-like slot: par_stream_start sets it before invoking the
   OCaml callback; do_invoke_stream_start reads it via caml_get_pending_stream_handle.
   Safe because par_stream_start holds ocaml_lock during the callback —
   only one stream can start at a time. */
static par_stream_handle_t* g_pending_stream_handle = NULL;

static void par_stream_enqueue_chunk(par_stream_handle_t* h, const char* json) {
    chunk_node_t* n = (chunk_node_t*)malloc(sizeof *n);
    if (!n) return;
    n->json = strdup(json);
    n->next = NULL;
    PAR_MUTEX_LOCK(h->q_mutex);
    if (h->q_tail) h->q_tail->next = n; else h->q_head = n;
    h->q_tail = n;
#ifndef _WIN32
    pthread_cond_signal(&h->q_cond);
#else
    WakeAllConditionVariable(&h->q_cond);
#endif
    PAR_MUTEX_UNLOCK(h->q_mutex);
}

static void par_stream_finish(par_stream_handle_t* h, const char* final_json, int is_error) {
    PAR_MUTEX_LOCK(h->q_mutex);
    ATOMIC_STORE_RELEASE(h->state, is_error ? PAR_STREAM_DONE_ERR : PAR_STREAM_DONE_OK);
    if (final_json) {
        free(h->final_json);
        h->final_json = strdup(final_json);
    }
#ifndef _WIN32
    pthread_cond_signal(&h->q_cond);
#else
    WakeAllConditionVariable(&h->q_cond);
#endif
    PAR_MUTEX_UNLOCK(h->q_mutex);
}

/* Called from OCaml work_loop (D1). Routes chunk to the correct handle's queue. */
value caml_dispatch_chunk_to_c_with_handle(value v_handle, value v_json) {
    CAMLparam2(v_handle, v_json);
    par_stream_handle_t* h = (par_stream_handle_t*)(Nativeint_val(v_handle));
    if (h) {
        const char* json = String_val(v_json);
        par_stream_enqueue_chunk(h, json);
    }
    CAMLreturn(Val_unit);
}

/* Called from OCaml work_loop (D1) on stream completion. */
value caml_stream_finish_to_c_byte(value v_handle, value v_json, value v_is_err) {
    CAMLparam3(v_handle, v_json, v_is_err);
    par_stream_handle_t* h = (par_stream_handle_t*)(Nativeint_val(v_handle));
    if (h) {
        const char* json = String_val(v_json);
        par_stream_finish(h, json, Int_val(v_is_err));
    }
    CAMLreturn(Val_unit);
}

/* Native-nargs-3 variant — used by OCaml when bytecode is not involved. */
value caml_stream_finish_to_c(value v_handle, value v_json, value v_is_err) {
    return caml_stream_finish_to_c_byte(v_handle, v_json, v_is_err);
}

/* Per-handle cancel state, polled by OCaml on_chunk. */
value caml_stream_cancel_state(value v_handle) {
    CAMLparam1(v_handle);
    par_stream_handle_t* h = (par_stream_handle_t*)(Nativeint_val(v_handle));
    int s = h ? ATOMIC_LOAD_ACQUIRE(h->state) : 0;
    CAMLreturn(Val_int(s));
}

/* OCaml reads the pending handle set by C-side par_stream_start. */
value caml_get_pending_stream_handle(value v_unit) {
    CAMLparam1(v_unit);
    CAMLreturn(caml_copy_nativeint((intnat)g_pending_stream_handle));
}

value caml_stream_cancel_requested(value v_unit) {
    CAMLparam1(v_unit);
    int v = ATOMIC_LOAD_ACQUIRE(g_stream_cancel_requested);
    CAMLreturn(Val_int(v));
}

static void ensure_initialized(void) {
    if (!ocaml_initialized) {
        caml_startup(caml_argv);
        ocaml_initialized = 1;
    }
}

static const value* lookup_cb(const char* name) {
    const value* cb = caml_named_value(name);
    if (cb == NULL) {
        fprintf(stderr, "P-A-R FFI: callback '%s' not found\n", name);
        exit(1);
    }
    return cb;
}

static value call1_exn(const char* name, value arg) {
    const value* cb = lookup_cb(name);
    return caml_callback_exn(*cb, arg);
}

static value call2_exn(const char* name, value a1, value a2) {
    const value* cb = lookup_cb(name);
    return caml_callback2_exn(*cb, a1, a2);
}

static value call3_exn(const char* name, value a1, value a2, value a3) {
    const value* cb = lookup_cb(name);
    return caml_callback3_exn(*cb, a1, a2, a3);
}

static value call4_exn(const char* name, value a1, value a2, value a3, value a4) {
    const value* cb = lookup_cb(name);
    value args[4] = {a1, a2, a3, a4};
    return caml_callbackN_exn(*cb, 4, args);
}

static value call5_exn(const char* name, value a1, value a2, value a3, value a4, value a5) {
    const value* cb = lookup_cb(name);
    value args[5] = {a1, a2, a3, a4, a5};
    return caml_callbackN_exn(*cb, 5, args);
}

static char* extract_string(value v) {
    if (Is_exception_result(v)) return NULL;
    return strdup(String_val(v));
}

/* --- Public API --- */

par_runtime_t* par_init(const char* config_json) {
    ensure_initialized();
    CAMLparam0();
    CAMLlocal1(c_config);

    c_config = caml_copy_string(config_json);

    PAR_MUTEX_LOCK(ocaml_lock);
    value rt_val = call1_exn("par_init", c_config);
    int is_exc = Is_exception_result(rt_val);
    PAR_MUTEX_UNLOCK(ocaml_lock);

    if (is_exc) {
        CAMLreturnT(par_runtime_t*, NULL);
    }

    par_runtime_t* handle = (par_runtime_t*)malloc(sizeof(par_runtime_t));
    if (!handle) {
        fprintf(stderr, "P-A-R FFI: malloc failed for runtime handle\n");
        CAMLreturnT(par_runtime_t*, NULL);
    }
    handle->_ocaml_value = rt_val;
    caml_register_generational_global_root(&handle->_ocaml_value);
    CAMLreturnT(par_runtime_t*, handle);
}

void par_shutdown(par_runtime_t* rt) {
    if (rt) {
        PAR_MUTEX_LOCK(ocaml_lock);
        call1_exn("par_shutdown", rt->_ocaml_value);
        caml_remove_global_root(&rt->_ocaml_value);
        PAR_MUTEX_UNLOCK(ocaml_lock);
        free(rt);
    }
}

int par_register_tool(par_runtime_t* rt, const char* name,
                      const char* description, const char* input_schema) {
    CAMLparam0();
    CAMLlocal3(c_name, c_desc, c_schema);

    c_name = caml_copy_string(name);
    c_desc = caml_copy_string(description);
    c_schema = caml_copy_string(input_schema);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call4_exn("par_register_tool", rt->_ocaml_value,
                             c_name, c_desc, c_schema);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}

int par_register_tool_with_handler(par_runtime_t* rt, const char* name,
                                    const char* description,
                                    const char* input_schema,
                                    int handler_id) {
    CAMLparam0();
    CAMLlocal3(c_name, c_desc, c_schema);
    value c_hid = Val_int(handler_id);

    c_name = caml_copy_string(name);
    c_desc = caml_copy_string(description);
    c_schema = caml_copy_string(input_schema);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call5_exn("par_register_tool_with_handler", rt->_ocaml_value,
                              c_name, c_desc, c_schema, c_hid);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}

int par_register_agent(par_runtime_t* rt, const char* config_json) {
    CAMLparam0();
    CAMLlocal1(c_config);
    c_config = caml_copy_string(config_json);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_register_agent", rt->_ocaml_value, c_config);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}

int par_register_skill(par_runtime_t* rt, const char* json) {
    CAMLparam0();
    CAMLlocal1(c_json);
    c_json = caml_copy_string(json);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_register_skill", rt->_ocaml_value, c_json);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}

char* par_list_skills(par_runtime_t* rt) {
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call1_exn("par_list_skills", rt->_ocaml_value);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    return ret;
}

char* par_list_llm_providers(par_runtime_t* rt) {
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call1_exn("par_list_llm_providers", rt->_ocaml_value);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    return ret;
}

int par_set_default_llm_provider(par_runtime_t* rt, const char* provider_id) {
    CAMLparam0();
    CAMLlocal1(c_id);
    c_id = caml_copy_string(provider_id);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_set_default_llm_provider", rt->_ocaml_value, c_id);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}

void par_set_session_id(par_runtime_t* rt, const char* session_id) {
    CAMLparam0();
    CAMLlocal1(c_sid);
    c_sid = caml_copy_string(session_id);
    PAR_MUTEX_LOCK(ocaml_lock);
    call2_exn("par_set_session_id", rt->_ocaml_value, c_sid);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturn0;
}

char* par_get_session_id(par_runtime_t* rt) {
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call1_exn("par_get_session_id", rt->_ocaml_value);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    return ret;
}

int par_save_conversation(par_runtime_t* rt) {
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call1_exn("par_save_conversation", rt->_ocaml_value);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    return rc;
}

int par_load_conversation(par_runtime_t* rt, const char* session_id) {
    CAMLparam0();
    CAMLlocal1(c_sid);
    c_sid = caml_copy_string(session_id);
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_load_conversation", rt->_ocaml_value, c_sid);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}

char* par_invoke(par_runtime_t* rt, const char* agent_id,
                 const char* message) {
    CAMLparam0();
    CAMLlocal2(c_aid, c_msg);
    c_aid = caml_copy_string(agent_id);
    c_msg = caml_copy_string(message);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call3_exn("par_invoke", rt->_ocaml_value, c_aid, c_msg);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

char* par_invoke_ext(par_runtime_t* rt, const char* agent_id,
                     const char* message, int save, int update_current) {
    CAMLparam0();
    CAMLlocal2(c_aid, c_msg);
    c_aid = caml_copy_string(agent_id);
    c_msg = caml_copy_string(message);

    PAR_MUTEX_LOCK(ocaml_lock);
    value args[5] = { rt->_ocaml_value, c_aid, c_msg,
                      Val_int(save), Val_int(update_current) };
    const value* cb = lookup_cb("par_invoke_ext");
    value result = caml_callbackN_exn(*cb, 5, args);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

char* par_generate(par_runtime_t* rt, const char* agent_id,
                   const char* message) {
    CAMLparam0();
    CAMLlocal2(c_aid, c_msg);
    c_aid = caml_copy_string(agent_id);
    c_msg = caml_copy_string(message);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call3_exn("par_generate", rt->_ocaml_value, c_aid, c_msg);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

char* par_generate_ext(par_runtime_t* rt, const char* agent_id,
                       const char* message, int save, int update_current) {
    CAMLparam0();
    CAMLlocal2(c_aid, c_msg);
    c_aid = caml_copy_string(agent_id);
    c_msg = caml_copy_string(message);

    PAR_MUTEX_LOCK(ocaml_lock);
    value args[5] = { rt->_ocaml_value, c_aid, c_msg,
                      Val_int(save), Val_int(update_current) };
    const value* cb = lookup_cb("par_generate_ext");
    value result = caml_callbackN_exn(*cb, 5, args);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

char* par_embed(par_runtime_t* rt, const char* messages_json) {
    CAMLparam0();
    CAMLlocal1(c_msgs);
    c_msgs = caml_copy_string(messages_json);

    PAR_MUTEX_LOCK(ocaml_lock);
    const value* cb = caml_named_value("par_embed");
    if (!cb) {
        PAR_MUTEX_UNLOCK(ocaml_lock);
        CAMLreturnT(char*, NULL);
    }
    value result = caml_callback2_exn(*cb, rt->_ocaml_value, c_msgs);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

int par_add_documents(par_runtime_t* rt, const char* docs_json) {
    CAMLparam0();
    CAMLlocal1(c_docs);
    c_docs = caml_copy_string(docs_json);

    PAR_MUTEX_LOCK(ocaml_lock);
    const value* cb = caml_named_value("par_add_documents");
    if (!cb) {
        PAR_MUTEX_UNLOCK(ocaml_lock);
        CAMLreturnT(int, -1);
    }
    value result = caml_callback2_exn(*cb, rt->_ocaml_value, c_docs);
    int ret = Is_exception_result(result) ? -99 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, ret);
}

char* par_load_document(par_runtime_t* rt, const char* path) {
    CAMLparam0();
    CAMLlocal1(c_path);
    c_path = caml_copy_string(path);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_load_document", rt->_ocaml_value, c_path);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

char* par_load_directory(par_runtime_t* rt, const char* path,
                         const char* loaders_json) {
    CAMLparam0();
    CAMLlocal2(c_path, c_loaders);
    c_path = caml_copy_string(path);
    c_loaders = caml_copy_string(loaders_json ? loaders_json : "");

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call3_exn("par_load_directory", rt->_ocaml_value,
                             c_path, c_loaders);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

char* par_invoke_with_rag(par_runtime_t* rt, const char* agent_id,
                         const char* message, const char* k_str) {
    CAMLparam0();
    CAMLlocal3(c_aid, c_msg, c_k);
    c_aid = caml_copy_string(agent_id);
    c_msg = caml_copy_string(message);
    c_k = caml_copy_string(k_str);

    PAR_MUTEX_LOCK(ocaml_lock);
    const value* cb = caml_named_value("par_invoke_with_rag");
    if (!cb) {
        PAR_MUTEX_UNLOCK(ocaml_lock);
        CAMLreturnT(char*, NULL);
    }
    value args[4] = { rt->_ocaml_value, c_aid, c_msg, c_k };
    value result = caml_callbackN_exn(*cb, 4, args);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

char* par_invoke_stream(par_runtime_t* rt, const char* agent_id,
                        const char* message,
                        par_chunk_callback cb, void* user_data) {
    CAMLparam0();
    CAMLlocal2(c_aid, c_msg);

    if (!rt || !agent_id || !message) CAMLreturnT(char*, NULL);

    ATOMIC_STORE_RELEASE(g_stream_cancel_requested, 0);
    g_chunk_callback = cb;
    g_chunk_user_data = user_data;

    c_aid = caml_copy_string(agent_id);
    c_msg = caml_copy_string(message);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call3_exn("par_invoke_stream", rt->_ocaml_value,
                             c_aid, c_msg);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);

    g_chunk_callback = NULL;
    g_chunk_user_data = NULL;

    CAMLreturnT(char*, ret);
}

void par_cancel_stream(par_runtime_t* rt) {
    (void)rt;
    ATOMIC_STORE_RELEASE(g_stream_cancel_requested, 1);
}

/* v0.7.10: par_stream_start enqueues streaming work on the work_loop Domain
   and returns immediately with a handle. The Python main thread is the
   only caller — registered with OCaml via caml_startup, holds D0. No
   foreign thread crosses into OCaml. */
par_stream_handle_t* par_stream_start(par_runtime_t* rt, const char* agent_id,
                                       const char* message) {
    if (!rt || !agent_id || !message) return NULL;
    par_stream_handle_t* h = (par_stream_handle_t*)calloc(1, sizeof *h);
    if (!h) return NULL;
    h->rt = rt;
#ifndef _WIN32
    pthread_mutex_init(&h->q_mutex, NULL);
    pthread_cond_init(&h->q_cond, NULL);
#else
    InitializeSRWLock(&h->q_mutex);
    InitializeConditionVariable(&h->q_cond);
#endif
    h->state = PAR_STREAM_RUNNING;

    CAMLparam0();
    CAMLlocal2(c_aid, c_msg);
    c_aid = caml_copy_string(agent_id);
    c_msg = caml_copy_string(message);

    PAR_MUTEX_LOCK(ocaml_lock);
    g_pending_stream_handle = h;
    value result = call3_exn("par_invoke_stream_start", rt->_ocaml_value,
                             c_aid, c_msg);
    g_pending_stream_handle = NULL;
    PAR_MUTEX_UNLOCK(ocaml_lock);

    if (Is_exception_result(result)) {
        CAMLdrop;
        free(h);
        return NULL;
    }
    CAMLdrop;
    return h;
}

/* Sentinel returned by par_stream_poll when stream is complete. */
#define PAR_STREAM_DONE ((char*)(intptr_t)1)

/* Pure C blocking poll. Returns:
   - chunk JSON string (caller must free) when a chunk is available
   - PAR_STREAM_DONE when stream completed (then call par_stream_take_final)
   - NULL when timeout elapsed with nothing available

   CRITICAL: releases the OCaml runtime before parking in
   pthread_cond_timedwait. Without this, D0 (the caml_startup thread that
   Python calls poll from) stays "active" from OCaml's perspective. When
   work_loop (D1) triggers major GC during HTTP I/O, STW waits for D0 to
   acknowledge — but D0 is parked and cannot. Result: HTTP I/O deadlocks.
   caml_release_runtime_system marks D0 as "idle" so STW auto-acknowledges. */
char* par_stream_poll(par_stream_handle_t* h, int timeout_ms) {
    if (!h) return NULL;
#ifndef _WIN32
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
#endif
    caml_release_runtime_system();
    PAR_MUTEX_LOCK(h->q_mutex);
    while (h->q_head == NULL &&
           ATOMIC_LOAD_ACQUIRE(h->state) == PAR_STREAM_RUNNING) {
#ifndef _WIN32
        int rc = pthread_cond_timedwait(&h->q_cond, &h->q_mutex, &deadline);
        if (rc == ETIMEDOUT) {
            PAR_MUTEX_UNLOCK(h->q_mutex);
            caml_acquire_runtime_system();
            return NULL;
        }
#else
        SleepConditionVariableSRW(&h->q_cond, &(h->q_mutex), (DWORD)timeout_ms, 0x01);
        if (h->q_head == NULL && ATOMIC_LOAD_ACQUIRE(h->state) == PAR_STREAM_RUNNING) {
            PAR_MUTEX_UNLOCK(h->q_mutex);
            caml_acquire_runtime_system();
            return NULL;
        }
#endif
    }
    if (h->q_head != NULL) {
        chunk_node_t* n = h->q_head;
        h->q_head = n->next;
        if (h->q_head == NULL) h->q_tail = NULL;
        char* json = n->json;
        free(n);
        PAR_MUTEX_UNLOCK(h->q_mutex);
        caml_acquire_runtime_system();
        return json;
    }
    PAR_MUTEX_UNLOCK(h->q_mutex);
    caml_acquire_runtime_system();
    return PAR_STREAM_DONE;
}

/* Cancel: atomic store, callable from any thread. */
void par_stream_cancel(par_stream_handle_t* h) {
    if (!h) return;
    ATOMIC_STORE_RELEASE(h->state, PAR_STREAM_CANCEL);
}

/* Steal the final result JSON (caller must free). Returns NULL if not done
   or no final was set. */
char* par_stream_take_final(par_stream_handle_t* h) {
    if (!h) return NULL;
    PAR_MUTEX_LOCK(h->q_mutex);
    char* r = h->final_json;
    h->final_json = NULL;
    PAR_MUTEX_UNLOCK(h->q_mutex);
    return r;
}

/* Free handle. Caller MUST ensure stream has completed (poll returned DONE). */
void par_stream_free(par_stream_handle_t* h) {
    if (!h) return;
    chunk_node_t* n = h->q_head;
    while (n) {
        chunk_node_t* nx = n->next;
        free(n->json);
        free(n);
        n = nx;
    }
    free(h->final_json);
#ifndef _WIN32
    pthread_mutex_destroy(&h->q_mutex);
    pthread_cond_destroy(&h->q_cond);
#endif
    free(h);
}

char* par_invoke_structured(par_runtime_t* rt, const char* agent_id,
                            const char* message, const char* schema_json) {
    CAMLparam0();
    CAMLlocal3(c_aid, c_msg, c_schema);
    c_aid = caml_copy_string(agent_id);
    c_msg = caml_copy_string(message);
    c_schema = caml_copy_string(schema_json);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call4_exn("par_invoke_structured", rt->_ocaml_value,
                             c_aid, c_msg, c_schema);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

char* par_submit_workflow(par_runtime_t* rt, const char* workflow_json) {
    CAMLparam0();
    CAMLlocal1(c_wf);
    c_wf = caml_copy_string(workflow_json);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_submit_workflow", rt->_ocaml_value, c_wf);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

int par_approve_workflow(par_runtime_t* rt, const char* run_id,
                         const char* approver) {
    CAMLparam0();
    CAMLlocal2(c_rid, c_apr);
    c_rid = caml_copy_string(run_id);
    c_apr = caml_copy_string(approver);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call3_exn("par_approve_workflow", rt->_ocaml_value,
                             c_rid, c_apr);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}

char* par_resume_workflow(par_runtime_t* rt, const char* run_id) {
    CAMLparam0();
    CAMLlocal1(c_rid);
    c_rid = caml_copy_string(run_id);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_resume_workflow", rt->_ocaml_value, c_rid);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

char* par_health(par_runtime_t* rt) {
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call1_exn("par_health", rt->_ocaml_value);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    return ret;
}

char* par_metrics(par_runtime_t* rt) {
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call1_exn("par_metrics", rt->_ocaml_value);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    return ret;
}

int par_steer(par_runtime_t* rt, const char* message) {
    CAMLparam0();
    CAMLlocal1(c_msg);
    c_msg = caml_copy_string(message);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_steer", rt->_ocaml_value, c_msg);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}

int par_follow_up(par_runtime_t* rt, const char* message) {
    CAMLparam0();
    CAMLlocal1(c_msg);
    c_msg = caml_copy_string(message);

    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_follow_up", rt->_ocaml_value, c_msg);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}

void par_result_free(par_result_t* result) {
    if (result) {
        PAR_MUTEX_LOCK(ocaml_lock);
        caml_remove_global_root(&result->_ocaml_value);
        free(result);
        PAR_MUTEX_UNLOCK(ocaml_lock);
    }
}

char* par_mcp_server(par_runtime_t* rt, const char* server_id) {
    CAMLparam0();
    CAMLlocal1(c_sid);
    c_sid = caml_copy_string(server_id);
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_mcp_server", rt->_ocaml_value, c_sid);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

char* par_mcp_list_tools(par_runtime_t* rt, const char* server_id) {
    CAMLparam0();
    CAMLlocal1(c_sid);
    c_sid = caml_copy_string(server_id);
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_mcp_list_tools", rt->_ocaml_value, c_sid);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

char* par_workflow_status(par_runtime_t* rt, const char* run_id) {
    CAMLparam0();
    CAMLlocal1(c_rid);
    c_rid = caml_copy_string(run_id);
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_workflow_status", rt->_ocaml_value, c_rid);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(char*, ret);
}

int par_workflow_cancel(par_runtime_t* rt, const char* run_id) {
    CAMLparam0();
    CAMLlocal1(c_rid);
    c_rid = caml_copy_string(run_id);
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_workflow_cancel", rt->_ocaml_value, c_rid);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}

int par_event_subscribe(par_runtime_t* rt, par_event_callback cb) {
    (void)cb;
    value c_cb = Val_int(0);
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call2_exn("par_event_subscribe", rt->_ocaml_value, c_cb);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    return rc;
}

char* par_version(void) {
    PAR_MUTEX_LOCK(ocaml_lock);
    ensure_initialized();
    value result = call1_exn("par_version", Val_unit);
    char* ret = extract_string(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    return ret;
}

int par_set_request_timeout(double seconds) {
    CAMLparam0();
    CAMLlocal1(c_secs);
    c_secs = caml_copy_double(seconds);
    PAR_MUTEX_LOCK(ocaml_lock);
    ensure_initialized();
    value result = call1_exn("par_set_request_timeout", c_secs);
    int rc = Is_exception_result(result) ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}

int par_set_vec_extension_path(const char* path) {
    if (!path) return -1;
    ensure_initialized();
    CAMLparam0();
    CAMLlocal1(c_path);
    c_path = caml_copy_string(path);
    PAR_MUTEX_LOCK(ocaml_lock);
    value result = call1_exn("par_set_vec_extension_path", c_path);
    int rc = Is_exception_result(result) ? -1 : Int_val(result);
    PAR_MUTEX_UNLOCK(ocaml_lock);
    CAMLreturnT(int, rc);
}
