#!/usr/bin/env python3
"""Example: Using PAR Runtime from Python with the typed API.

This demonstrates the v0.18 workflow:
1. Initialize the runtime with a typed RuntimeConfig
2. Register tools
3. Register a typed AgentConfig
4. Invoke with invoke_result() (needs an LLM provider)

Prerequisites:
  - Build the shared library: dune build lib/ffi/par_capi.so
  - Set PAR_RUNTIME_LIB or run from project root
  - Set an LLM provider (for example OPENAI_API_KEY) before invoking

Usage:
  python3 examples/basic_agent.py
"""

import json
import os
import sys


sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from par_runtime import (
    AgentConfig,
    ModelConfig,
    PARError,
    Runtime,
    RuntimeConfig,
    ToolSpec,
)


def main():
    config = RuntimeConfig(persistence="par_agent.db")

    print("=== P-A-R Python Example ===\n")
    print("Initializing runtime with typed RuntimeConfig + SQLite persistence...")

    try:
        with Runtime(config) as rt:
            print(f"  Runtime: {rt}")

            print("\nRegistering tools...")
            rt.register_tool(
                name="calculator",
                description="Evaluate arithmetic expressions",
                input_schema=json.dumps({
                    "type": "object",
                    "properties": {
                        "expression": {"type": "string"}
                    },
                    "required": ["expression"]
                }),
            )
            print("  [+] calculator tool registered")

            rt.register_tool(
                name="echo",
                description="Echo back the input",
                input_schema=json.dumps({
                    "type": "object",
                    "properties": {
                        "message": {"type": "string"}
                    },
                    "required": ["message"]
                }),
            )
            print("  [+] echo tool registered")

            agent = AgentConfig(
                id="example-agent",
                system_prompt="You are a concise assistant. Use tools when useful.",
                model=ModelConfig(
                    provider="openai",
                    model_name="gpt-4o-mini",
                    temperature=0.2,
                ),
                tools=[
                    ToolSpec(name="calculator", description="Evaluate arithmetic"),
                    ToolSpec(name="echo", description="Echo back the input"),
                ],
            )
            rt.register_agent(agent)
            print("  [+] typed agent registered")

            print("\n=== Done ===")
            print("Agent invocation requires an LLM provider:")
            print("  result = rt.invoke_result('example-agent', 'Hello!')")
            print("Set OPENAI_API_KEY (or another configured provider) to run it.")

    except PARError as e:
        print(f"\nPAR Error: {e}")
        print("Make sure par_capi.so is built: dune build lib/ffi/par_capi.so")
        sys.exit(1)


if __name__ == "__main__":
    main()
