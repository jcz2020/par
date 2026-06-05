#!/usr/bin/env bash
set -euo pipefail

read -r -d '' IDENTS <<'EOF' || true
par;PK
par_cli;PK
par_runtime;PK
par_postgres;PK
Runtime.create;API
Runtime.invoke;API
Runtime.register_tool;API
Runtime.register_agent;API
Runtime.mcp_server;API
`Openai;LLM
`Anthropic;LLM
`Mock;LLM
`Ollama;LLM
`Sqlite;PER
`Postgresql;PER
`Noop;PER
par;CLI
par config;CLI
par ask;CLI
par --version;CLI
Bash_safe_command;BSH
Bash_policy;BSH
Bash_blacklist;BSH
Bash_invoked;BSH
Bash_completed;BSH
Mcp_server_started;MCP
Mcp_server_failed;MCP
Mcp_server_stopped;MCP
Mcp_tool_invoked;MCP
Mcp_tool_completed;MCP
Mcp_resource_read;MCP
Mcp_prompt_rendered;MCP
~/.par/config.json;PTH
lib/par.ml;PTH
docs/sdk/;PTH
event_bus.max_queue_size;JSN
dlq_enabled;JSN
default_quota.max_concurrent_tasks;JSN
parallel_tool_execution;JSN
EOF

declare -A TOT=( [PK]=4 [API]=5 [LLM]=4 [PER]=3 [CLI]=4 [BSH]=5 [MCP]=7 [PTH]=3 [JSN]=4 )

req_for() { case "$1" in
  */README.md|README.md)                                  echo "PK:1 CLI:1 PTH:1" ;;
  */docs/cli.md|docs/cli.md|*/docs/quickstart.md|docs/quickstart.md) echo "CLI:1 PK:1" ;;
  */docs/index.md|docs/index.md)                          echo "PK:1" ;;
  */docs/sdk/mcp.md|docs/sdk/mcp.md)                      echo "MCP:1 API:1" ;;
  */docs/sdk/*|docs/sdk/*)                                echo "API:1" ;;
  */docs/howto/*|docs/howto/*)                            echo "ANY:1" ;;
  */docs/explanation/*|docs/explanation/*)                echo "API:1 PTH:1" ;;
  *)                                                      echo "" ;;
esac; }

strip_code() { awk '/^```/{c=!c;next} /^~~~/{c=!c;next} !c' "$1"; }

check() {
  local f=$1 text fail=0 present=0
  text=$(strip_code "$f")
  declare -A seen=([PK]=0 [API]=0 [LLM]=0 [PER]=0 [CLI]=0 [BSH]=0 [MCP]=0 [PTH]=0 [JSN]=0) miss=()
  while IFS=';' read -r id cat; do
    [ -n "$id" ] && { printf '%s' "$text" | grep -qF -- "$id" \
      && { seen[$cat]=$(( ${seen[$cat]} + 1 )); present=$((present+1)); } \
      || miss+=("$cat:$id"); }
  done <<< "$IDENTS"
  echo "=== $f ==="
  for cat in API LLM PTH PK CLI BSH MCP JSN PER; do
    [ "${seen[$cat]}" -gt 0 ] && echo "  ✓ ${seen[$cat]}/${TOT[$cat]} $cat present"
  done
  for r in $(req_for "$f"); do
    c=${r%:*}; m=${r#*:}
    if [ "$c" = "ANY" ]; then
      [ "$present" -ge "$m" ] || { fail=1; echo "  ✗ No canonical identifier found in any category"; }
    elif [ "${seen[$c]}" -lt "$m" ]; then
      fail=1
      for e in "${miss[@]}"; do
        [ "${e%%:*}" = "$c" ] && echo "  ✗ Missing expected identifier: \`${e#*:}\`"
      done
    fi
  done
  if [ "$fail" -eq 1 ]; then
    echo "  Total: $present/39 expected identifiers found (FAIL)"; return 1
  fi
  echo "  Total: $present/39 expected identifiers found"
}

main() {
  local files=("$@") rc=0
  [ ${#files[@]} -eq 0 ] && { shopt -s globstar nullglob; files=(README.md docs/**/*.md); }
  for f in "${files[@]}"; do
    [ -f "$f" ] && { check "$f" || rc=1; }
  done
  exit "$rc"
}

main "$@"
