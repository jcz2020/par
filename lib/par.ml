(** P-A-R SDK — Facade module.

    [open Par] brings all SDK modules into scope:
    Types, Runtime, Engine, Expression, Workflow_engine,
    State_machine, Context_manager, Cancellation,
    Tool_registry, Openai_provider, Anthropic_provider,
     Sqlite_persistence, Noop_persistence,
     Event_bus, Builtin_tools,
    Logging, Retry, Rate_limit, Timeout, Validation, Pii_mask,
    Sanitize_tool_output *)

module Types = Types
module Runtime = Runtime
module Engine = Engine
module Expression = Expression
module Workflow_engine = Workflow_engine
module State_machine = State_machine
module Context_manager = Context_manager
module Cancellation = Cancellation
module Tool_registry = Tool_registry

module Openai_provider = Openai_provider
module Anthropic_provider = Anthropic_provider
module Mock_provider = Mock_provider

module Sqlite_persistence = Sqlite_persistence
module Noop_persistence = Noop_persistence

module Event_bus = Event_bus

module Builtin_tools = Builtin_tools

module Logging = Logging
module Retry = Retry
module Rate_limit = Rate_limit
module Timeout = Timeout
module Validation = Validation
module Pii_mask = Pii_mask
module Sanitize_tool_output = Sanitize_tool_output
