#!/usr/bin/env python3
"""Example: Using PAR Runtime from Python.

This demonstrates the basic workflow:
1. Initialize runtime with SQLite persistence
2. Register a tool
3. Register an agent
4. Invoke the agent

Prerequisites:
  - Build the shared library: dune build lib/ffi/par_capi.so
  - Set PAR_RUNTIME_LIB or run from project root

Usage:
  python3 examples/basic_agent.py
"""

import json
import os
import sys


sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from par_runtime import Runtime, PARError


def main():
    config = json.dumps({
        "persistence": {"tag": "sqlite", "contents": "par_agent.db"},
        "event_bus": {
            "max_queue_size": 100,
            "dlq_enabled": False,
            "dlq_max_size": 10,
        },
        "default_quota": {
            "max_tokens": 4096,
            "max_iterations": 10,
            "timeout_seconds": 30.0,
        },
        "shutdown": {
            "grace_period_seconds": 5.0,
            "force_after_seconds": 10.0,
        },
        "llm_providers": [],
    })

    print("=== P-A-R Python Example ===\n")
    print(f"Initializing runtime with SQLite persistence...")

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

            print(f"\n  Runtime state: {rt}")

            print("\n=== Done ===")
            print("Note: Agent invocation requires an LLM provider.")
            print("Configure via 'par config' or set PAR_RUNTIME_LIB.")

    except PARError as e:
        print(f"\nPAR Error: {e}")
        print("Make sure par_capi.so is built: dune build lib/ffi/par_capi.so")
        sys.exit(1)


if __name__ == "__main__":
    main()