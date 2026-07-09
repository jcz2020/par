val timeout_middleware :
  default_timeout:float ->
  Types.middleware_hook
  [@@deprecated
    "since v0.6.4 (PAR-19b): the middleware_hook contract cannot enforce \
     timeouts; use Par.Types.agent_config.tool_timeout via \
     Runtime.make_agent ~tool_timeout:<seconds>. This no-op shim is \
     removed in v0.8."]
