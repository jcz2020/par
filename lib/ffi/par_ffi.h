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
int par_register_tool_with_handler(par_runtime_t* rt, const char* name,
                                    const char* description,
                                    const char* input_schema,
                                    int handler_id);

typedef char* (*par_tool_callback)(int handler_id, const char* input_json);
void par_store_python_handler(int handler_id, par_tool_callback fn);

/* Agent registration */
int par_register_agent(par_runtime_t* rt, const char* config_json);

/* Synchronous invocation — returns JSON string, caller must free() */
char* par_invoke(par_runtime_t* rt, const char* agent_id,
                 const char* message);

char* par_embed(par_runtime_t* rt, const char* messages_json);

int par_add_documents(par_runtime_t* rt, const char* docs_json);

char* par_invoke_with_rag(par_runtime_t* rt, const char* agent_id,
                         const char* message, const char* k_str);

/* Streaming invocation — invokes an agent and dispatches each
   llm_response_chunk to the supplied callback as a JSON string. The
   callback receives the chunk JSON plus the user_data pointer that
   was registered with par_invoke_stream; ownership of the JSON
   string is held by the runtime, so the callback must copy it
   before returning if it needs to outlive the call.
   Returns the final result JSON string (caller must free()) or
   NULL on error. */
typedef void (*par_chunk_callback)(const char* json_chunk, void* user_data);
char* par_invoke_stream(par_runtime_t* rt, const char* agent_id,
                        const char* message,
                        par_chunk_callback cb, void* user_data);

/* Synchronous structured invocation — returns JSON envelope with value/raw/attempts.
   Caller must free(). schema_json is a JSON-encoded JSON Schema string. */
char* par_invoke_structured(par_runtime_t* rt, const char* agent_id,
                            const char* message, const char* schema_json);

/* Workflow API */
char* par_submit_workflow(par_runtime_t* rt, const char* workflow_json);
int   par_approve_workflow(par_runtime_t* rt, const char* run_id,
                           const char* approver);
char* par_resume_workflow(par_runtime_t* rt, const char* run_id);

/* Observability — returns JSON string, caller must free() */
char* par_health(par_runtime_t* rt);
char* par_metrics(par_runtime_t* rt);

/* Steering — inject messages into in-flight or queued agent runs */
int par_steer(par_runtime_t* rt, const char* message);
int par_follow_up(par_runtime_t* rt, const char* message);

/* MCP access */
char* par_mcp_server(par_runtime_t* rt, const char* server_id);
char* par_mcp_list_tools(par_runtime_t* rt, const char* server_id);

/* Workflow status/cancel */
char* par_workflow_status(par_runtime_t* rt, const char* run_id);
int   par_workflow_cancel(par_runtime_t* rt, const char* run_id);

/* Event subscription */
typedef void (*par_event_callback)(const char* event_type, const char* event_json);
int par_event_subscribe(par_runtime_t* rt, par_event_callback cb);

/* Version */
char* par_version(void);
int   par_set_request_timeout(double seconds);

/* Cleanup */
void par_result_free(par_result_t* result);

#ifdef __cplusplus
}
#endif

#endif /* PAR_FFI_H */
