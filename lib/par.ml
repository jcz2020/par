(** P-A-R SDK — Facade module.

    [open Par] brings all SDK modules into scope:
    Types, Runtime, Engine, Expression, Workflow_engine,
    State_machine, Context_manager, Cancellation,
    Tool_registry, Openai_provider, Anthropic_provider,
     Sqlite_persistence, Noop_persistence,
     Event_bus, Persistence_writer, Builtin_tools,
    Logging, Retry, Rate_limit, Timeout, Arg_validation, Output_validation, Pii_mask,
    Sanitize_tool_output. JSON Schema validation lives in [Validation]. *)

module Types = Types
module Workspace = Workspace
module Runtime = Runtime
module Engine = Engine
module Template = Template
module Steering_queue = Steering_queue
module Metrics = Metrics
module Hook = Hook
module Expression = Expression
module Workflow_engine = Workflow_engine
module State_machine = State_machine
module Context_manager = Context_manager
module Message = Message
module Cache_breakpoint = Cache_breakpoint
module Cancellation = Cancellation
module Chunking = Chunking
module Document = Document
module Html_loader = Html_loader
module Pdf_loader = Pdf_loader
module Text_loader = Text_loader
module Markdown_loader = Markdown_loader
module Csv_loader = Csv_loader
module Directory_loader = Directory_loader
module Vector_store = Vector_store
module Tool_registry = Tool_registry
module Skill_registry = Skill_registry
module Skill_loader = Skill_loader
module Builtin_skills = Builtin_skills
module Jsonschema = Jsonschema
module Tool_prompt = Tool_prompt
module Http_timeout = Http_timeout

module Openai_provider = Openai_provider
module Anthropic_provider = Anthropic_provider
module Mock_provider = Mock_provider
module Http_client = Http_client

module Sqlite_persistence = Sqlite_persistence
module Noop_persistence = Noop_persistence
module Persistence_common = Persistence_common

module Event_bus = Event_bus
module Persistence_writer = Persistence_writer
module Cli_util = Cli_util

module Builtin_tools = Builtin_tools
module Bash_safe_command = Bash_safe_command
module Bash_blacklist = Bash_blacklist
module Bash_policy = Bash_policy
module Bash_confirm = Bash_confirm

module Logging = Logging
module Retry = Retry
module Rate_limit = Rate_limit
module Timeout = Timeout
module Arg_validation = Arg_validation
module Output_validation = Output_validation
module Validation = Validation
module Json_extract = Json_extract
module Pii_mask = Pii_mask
module Sanitize_tool_output = Sanitize_tool_output
module Version = Version

module Mcp_types = Mcp_types
module Mcp_server = Mcp_server
module Mcp_client = Mcp_client
module Mcp_errors = Mcp_errors
module Mcp_naming = Mcp_naming
module Mcp_transport = Mcp_transport
module Mcp_transport_stdio = Mcp_transport_stdio
module Mcp_transport_http = Mcp_transport_http
