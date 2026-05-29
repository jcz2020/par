/* par_ffi.c — C implementation of the P-A-R FFI bridge.
   Bridges C callers to OCaml runtime via caml_callback. */

#include "par_ffi.h"
#include <caml/mlvalues.h>
#include <caml/callback.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Opaque handle structs — each wraps an OCaml value with a GC root */
struct par_runtime {
    value _ocaml_value;
};

struct par_result {
    value _ocaml_value;
};

/* Auto-initialize OCaml runtime on dlopen */
static char* caml_argv[] = { "par_ffi", NULL };
static int ocaml_initialized = 0;

static void ensure_initialized(void) {
    if (!ocaml_initialized) {
        caml_startup(caml_argv);
        ocaml_initialized = 1;
    }
}

/* Helper: look up a named OCaml callback */
static const value* lookup_cb(const char* name) {
    const value* cb = caml_named_value(name);
    if (cb == NULL) {
        fprintf(stderr, "P-A-R FFI: callback '%s' not found\n", name);
        exit(1);
    }
    return cb;
}

/* Helper: call 1-arg OCaml function, returns value */
static value call1(const char* name, value arg) {
    const value* cb = lookup_cb(name);
    return caml_callback_exn(*cb, arg);
}

/* Helper: call 2-arg OCaml function */
static value call2(const char* name, value a1, value a2) {
    const value* cb = lookup_cb(name);
    return caml_callback2_exn(*cb, a1, a2);
}

/* Helper: call 3-arg OCaml function */
static value call3(const char* name, value a1, value a2, value a3) {
    const value* cb = lookup_cb(name);
    return caml_callback3_exn(*cb, a1, a2, a3);
}

/* Helper: check exception result and return NULL on error */
static char* extract_string(value v) {
    if (Is_exception_result(v)) return NULL;
    return strdup(String_val(v));
}

/* --- Public API --- */

par_runtime_t* par_init(const char* config_json) {
    ensure_initialized();
    value c_config = caml_copy_string(config_json);
    value rt_val = call1("par_init", c_config);
    if (Is_exception_result(rt_val)) return NULL;
    par_runtime_t* handle = (par_runtime_t*)malloc(sizeof(par_runtime_t));
    if (handle) {
        handle->_ocaml_value = rt_val;
        caml_register_generational_global_root(&handle->_ocaml_value);
    }
    return handle;
}

void par_shutdown(par_runtime_t* rt) {
    if (rt) {
        caml_remove_global_root(&rt->_ocaml_value);
        free(rt);
    }
}

int par_register_tool(par_runtime_t* rt, const char* name,
                      const char* description, const char* input_schema) {
    value c_name = caml_copy_string(name);
    value c_desc = caml_copy_string(description);
    value c_schema = caml_copy_string(input_schema);
    value result = call3("par_register_tool", rt->_ocaml_value, c_name, c_desc);
    (void)c_schema;
    if (Is_exception_result(result)) return -1;
    return Int_val(result);
}

int par_register_agent(par_runtime_t* rt, const char* config_json) {
    value c_config = caml_copy_string(config_json);
    value result = call2("par_register_agent", rt->_ocaml_value, c_config);
    if (Is_exception_result(result)) return -1;
    return Int_val(result);
}

char* par_invoke(par_runtime_t* rt, const char* agent_id,
                 const char* message) {
    value c_aid = caml_copy_string(agent_id);
    value c_msg = caml_copy_string(message);
    value result = call3("par_invoke", rt->_ocaml_value, c_aid, c_msg);
    return extract_string(result);
}

char* par_submit_workflow(par_runtime_t* rt, const char* workflow_json) {
    value c_wf = caml_copy_string(workflow_json);
    value result = call2("par_submit_workflow", rt->_ocaml_value, c_wf);
    return extract_string(result);
}

int par_approve_workflow(par_runtime_t* rt, const char* run_id,
                         const char* approver) {
    value c_rid = caml_copy_string(run_id);
    value c_apr = caml_copy_string(approver);
    value result = call3("par_approve_workflow", rt->_ocaml_value, c_rid, c_apr);
    if (Is_exception_result(result)) return -1;
    return Int_val(result);
}

char* par_resume_workflow(par_runtime_t* rt, const char* run_id) {
    value c_rid = caml_copy_string(run_id);
    value result = call2("par_resume_workflow", rt->_ocaml_value, c_rid);
    return extract_string(result);
}

void par_result_free(par_result_t* result) {
    if (result) {
        caml_remove_global_root(&result->_ocaml_value);
        free(result);
    }
}
