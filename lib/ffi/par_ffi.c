/* par_ffi.c — C implementation of the P-A-R FFI bridge.
   Bridges C callers to OCaml runtime via caml_callback.
   Thread-safe: pthread_mutex serializes callbacks.
   Allocation (caml_copy_string) is done OUTSIDE the lock to prevent
   longjmp from OCaml OOM skipping pthread_mutex_unlock. */

#include "par_ffi.h"
#include <caml/mlvalues.h>
#include <caml/callback.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>

struct par_runtime {
    value _ocaml_value;
};

struct par_result {
    value _ocaml_value;
};

static char* caml_argv[] = { "par_ffi", NULL };
static int ocaml_initialized = 0;
static pthread_mutex_t ocaml_lock = PTHREAD_MUTEX_INITIALIZER;

#define MAX_PYTHON_HANDLERS 256
static par_tool_callback python_handler_table[MAX_PYTHON_HANDLERS];

void par_store_python_handler(int handler_id, par_tool_callback fn) {
    if (handler_id >= 0 && handler_id < MAX_PYTHON_HANDLERS) {
        python_handler_table[handler_id] = fn;
    }
}

value caml_invoke_python_handler(value v_handler_id, value v_input_json) {
    int handler_id = Int_val(v_handler_id);
    const char* input = String_val(v_input_json);
    if (handler_id >= 0 && handler_id < MAX_PYTHON_HANDLERS && python_handler_table[handler_id] != NULL) {
        char* result = python_handler_table[handler_id](handler_id, input);
        if (result != NULL) {
            value v_result = caml_copy_string(result);
            free(result);
            return v_result;
        }
    }
    return caml_copy_string("");
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
    pthread_mutex_lock(&ocaml_lock);
    ensure_initialized();
    pthread_mutex_unlock(&ocaml_lock);

    /* caml_copy_string can raise OOM via longjmp — must be outside lock */
    value c_config = caml_copy_string(config_json);

    pthread_mutex_lock(&ocaml_lock);
    value rt_val = call1_exn("par_init", c_config);
    int is_exc = Is_exception_result(rt_val);
    pthread_mutex_unlock(&ocaml_lock);

    if (is_exc) return NULL;

    par_runtime_t* handle = (par_runtime_t*)malloc(sizeof(par_runtime_t));
    if (!handle) {
        fprintf(stderr, "P-A-R FFI: malloc failed for runtime handle\n");
        return NULL;
    }
    handle->_ocaml_value = rt_val;
    caml_register_generational_global_root(&handle->_ocaml_value);
    return handle;
}

void par_shutdown(par_runtime_t* rt) {
    if (rt) {
        pthread_mutex_lock(&ocaml_lock);
        call1_exn("par_shutdown", rt->_ocaml_value);
        caml_remove_global_root(&rt->_ocaml_value);
        pthread_mutex_unlock(&ocaml_lock);
        free(rt);
    }
}

/* Register a custom tool with the PAR runtime.
 * Returns: 0  on success
 *         -1  on general error (invalid handle, internal failure)
 *         -2  on invalid schema (malformed JSON or not a JSON object)
 *         -3  on empty tool name
 *         -4  on duplicate tool name */
int par_register_tool(par_runtime_t* rt, const char* name,
                      const char* description, const char* input_schema) {
    /* caml_copy_string can raise — outside lock */
    value c_name = caml_copy_string(name);
    value c_desc = caml_copy_string(description);
    value c_schema = caml_copy_string(input_schema);

    /* Only callback invocation inside lock */
    pthread_mutex_lock(&ocaml_lock);
    value result = call4_exn("par_register_tool", rt->_ocaml_value,
                             c_name, c_desc, c_schema);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    pthread_mutex_unlock(&ocaml_lock);
    return rc;
}

/* Register a tool with a Python callback handler.
 * handler_id maps to a callback in the handler table managed by par_capi.ml.
 * Returns: 0 on success, negative on error (same codes as par_register_tool). */
int par_register_tool_with_handler(par_runtime_t* rt, const char* name,
                                    const char* description,
                                    const char* input_schema,
                                    int handler_id) {
    value c_name = caml_copy_string(name);
    value c_desc = caml_copy_string(description);
    value c_schema = caml_copy_string(input_schema);
    value c_hid = Val_int(handler_id);

    pthread_mutex_lock(&ocaml_lock);
    value result = call5_exn("par_register_tool_with_handler", rt->_ocaml_value,
                              c_name, c_desc, c_schema, c_hid);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    pthread_mutex_unlock(&ocaml_lock);
    return rc;
}

int par_register_agent(par_runtime_t* rt, const char* config_json) {
    value c_config = caml_copy_string(config_json);

    pthread_mutex_lock(&ocaml_lock);
    value result = call2_exn("par_register_agent", rt->_ocaml_value, c_config);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    pthread_mutex_unlock(&ocaml_lock);
    return rc;
}

char* par_invoke(par_runtime_t* rt, const char* agent_id,
                 const char* message) {
    value c_aid = caml_copy_string(agent_id);
    value c_msg = caml_copy_string(message);

    pthread_mutex_lock(&ocaml_lock);
    value result = call3_exn("par_invoke", rt->_ocaml_value, c_aid, c_msg);
    char* ret = extract_string(result);
    pthread_mutex_unlock(&ocaml_lock);
    return ret;
}

char* par_submit_workflow(par_runtime_t* rt, const char* workflow_json) {
    value c_wf = caml_copy_string(workflow_json);

    pthread_mutex_lock(&ocaml_lock);
    value result = call2_exn("par_submit_workflow", rt->_ocaml_value, c_wf);
    char* ret = extract_string(result);
    pthread_mutex_unlock(&ocaml_lock);
    return ret;
}

int par_approve_workflow(par_runtime_t* rt, const char* run_id,
                         const char* approver) {
    value c_rid = caml_copy_string(run_id);
    value c_apr = caml_copy_string(approver);

    pthread_mutex_lock(&ocaml_lock);
    value result = call3_exn("par_approve_workflow", rt->_ocaml_value,
                             c_rid, c_apr);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    pthread_mutex_unlock(&ocaml_lock);
    return rc;
}

char* par_resume_workflow(par_runtime_t* rt, const char* run_id) {
    value c_rid = caml_copy_string(run_id);

    pthread_mutex_lock(&ocaml_lock);
    value result = call2_exn("par_resume_workflow", rt->_ocaml_value, c_rid);
    char* ret = extract_string(result);
    pthread_mutex_unlock(&ocaml_lock);
    return ret;
}

char* par_health(par_runtime_t* rt) {
    pthread_mutex_lock(&ocaml_lock);
    value result = call1_exn("par_health", rt->_ocaml_value);
    char* ret = extract_string(result);
    pthread_mutex_unlock(&ocaml_lock);
    return ret;
}

char* par_metrics(par_runtime_t* rt) {
    pthread_mutex_lock(&ocaml_lock);
    value result = call1_exn("par_metrics", rt->_ocaml_value);
    char* ret = extract_string(result);
    pthread_mutex_unlock(&ocaml_lock);
    return ret;
}

int par_steer(par_runtime_t* rt, const char* message) {
    value c_msg = caml_copy_string(message);

    pthread_mutex_lock(&ocaml_lock);
    value result = call2_exn("par_steer", rt->_ocaml_value, c_msg);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    pthread_mutex_unlock(&ocaml_lock);
    return rc;
}

int par_follow_up(par_runtime_t* rt, const char* message) {
    value c_msg = caml_copy_string(message);

    pthread_mutex_lock(&ocaml_lock);
    value result = call2_exn("par_follow_up", rt->_ocaml_value, c_msg);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    pthread_mutex_unlock(&ocaml_lock);
    return rc;
}

void par_result_free(par_result_t* result) {
    if (result) {
        pthread_mutex_lock(&ocaml_lock);
        caml_remove_global_root(&result->_ocaml_value);
        free(result);
        pthread_mutex_unlock(&ocaml_lock);
    }
}

char* par_mcp_server(par_runtime_t* rt, const char* server_id) {
    value c_sid = caml_copy_string(server_id);
    pthread_mutex_lock(&ocaml_lock);
    value result = call2_exn("par_mcp_server", rt->_ocaml_value, c_sid);
    char* ret = extract_string(result);
    pthread_mutex_unlock(&ocaml_lock);
    return ret;
}

char* par_mcp_list_tools(par_runtime_t* rt, const char* server_id) {
    value c_sid = caml_copy_string(server_id);
    pthread_mutex_lock(&ocaml_lock);
    value result = call2_exn("par_mcp_list_tools", rt->_ocaml_value, c_sid);
    char* ret = extract_string(result);
    pthread_mutex_unlock(&ocaml_lock);
    return ret;
}

char* par_workflow_status(par_runtime_t* rt, const char* run_id) {
    value c_rid = caml_copy_string(run_id);
    pthread_mutex_lock(&ocaml_lock);
    value result = call2_exn("par_workflow_status", rt->_ocaml_value, c_rid);
    char* ret = extract_string(result);
    pthread_mutex_unlock(&ocaml_lock);
    return ret;
}

int par_workflow_cancel(par_runtime_t* rt, const char* run_id) {
    value c_rid = caml_copy_string(run_id);
    pthread_mutex_lock(&ocaml_lock);
    value result = call2_exn("par_workflow_cancel", rt->_ocaml_value, c_rid);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    pthread_mutex_unlock(&ocaml_lock);
    return rc;
}

int par_event_subscribe(par_runtime_t* rt, par_event_callback cb) {
    (void)cb;
    value c_cb = Val_int(0);
    pthread_mutex_lock(&ocaml_lock);
    value result = call2_exn("par_event_subscribe", rt->_ocaml_value, c_cb);
    int is_exc = Is_exception_result(result);
    int rc = is_exc ? -1 : Int_val(result);
    pthread_mutex_unlock(&ocaml_lock);
    return rc;
}

char* par_version(void) {
    pthread_mutex_lock(&ocaml_lock);
    ensure_initialized();
    value result = call1_exn("par_version", Val_unit);
    char* ret = extract_string(result);
    pthread_mutex_unlock(&ocaml_lock);
    return ret;
}
