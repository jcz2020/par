#ifndef PAR_FFI_H
#define PAR_FFI_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handles */
typedef struct par_runtime par_runtime_t;
typedef struct par_result  par_result_t;

/* Lifecycle */
par_runtime_t* par_init(const char* config_json);
void           par_shutdown(par_runtime_t* rt);

/* Tool registration */
int par_register_tool(par_runtime_t* rt, const char* name,
                      const char* description, const char* input_schema);

/* Agent registration */
int par_register_agent(par_runtime_t* rt, const char* config_json);

/* Synchronous invocation — returns JSON string, caller must free() */
char* par_invoke(par_runtime_t* rt, const char* agent_id,
                 const char* message);

/* Workflow API */
char* par_submit_workflow(par_runtime_t* rt, const char* workflow_json);
int   par_approve_workflow(par_runtime_t* rt, const char* run_id,
                           const char* approver);
char* par_resume_workflow(par_runtime_t* rt, const char* run_id);

/* Cleanup */
void par_result_free(par_result_t* result);

#ifdef __cplusplus
}
#endif

#endif /* PAR_FFI_H */
