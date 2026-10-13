#!/usr/bin/env bash
# check_test_wiring.sh — Detect test files that exist but never run.
#
# A test module that is written but never registered in test/dune is worse
# than no test at all: it looks like coverage in code review, yet dune never
# compiles it. Such a file silently rots — it keeps failing to build after an
# API change, and nobody notices because nothing ever tried to compile it.
#
# This has bitten this repo three times (v0.7.x hotfix era, v0.11 tool train,
# and test_chunking, which rotted unused from v0.5.1 for ~3.5 months). The
# invariant is trivially machine-checkable, so check it mechanically instead
# of relying on discipline: every test/test_*.ml must appear in some
# (modules ...) stanza of test/dune.
#
# Usage:
#   bash scripts/check_test_wiring.sh           # report unwired test files
#   bash scripts/check_test_wiring.sh --strict  # exit 1 if any found
#
# Exit codes:
#   0 = every test file is wired into test/dune
#   1 = unwired test file(s) found (strict mode)
#   2 = bad usage

set -euo pipefail

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --help|-h) sed -n '2,^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$REPO_ROOT/test"
DUNE_FILE="$TEST_DIR/dune"

if [[ ! -f "$DUNE_FILE" ]]; then
  echo "ERROR: $DUNE_FILE not found" >&2
  exit 2
fi

# Test modules present on disk.
ON_DISK="$(find "$TEST_DIR" -maxdepth 1 -name 'test_*.ml' -exec basename {} .ml \; \
  | sort -u)"

# Modules registered in test/dune, across all (modules ...) stanzas.
IN_DUNE="$(grep -oE '\(modules [^)]*\)' "$DUNE_FILE" \
  | sed 's/(modules //; s/)//' \
  | tr ' ' '\n' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | grep -v '^$' \
  | sort -u)"

# Modules referenced by dune but absent from disk (stale references).
MISSING="$(comm -13 <(echo "$ON_DISK") <(echo "$IN_DUNE") || true)"
# Test files on disk that dune never builds.
UNWIRED="$(comm -23 <(echo "$ON_DISK") <(echo "$IN_DUNE") || true)"

# Filter out non-test helpers referenced by dune stanzas (executables and
# mock servers legitimately have no test_*.ml counterpart).
MISSING_FILTERED="$(echo "$MISSING" | grep -v -E '^(manual_qa_assistant|mcp_mock_server)$' || true)"

status=0

if [[ -n "$UNWIRED" ]]; then
  echo "ERROR: test file(s) present but never registered in test/dune."
  echo "These modules are never compiled and never run:"
  echo "$UNWIRED" | sed 's/^/  - /'
  echo
  echo "Add a stanza to test/dune, e.g.:"
  echo "  (test"
  echo "   (name <module_name>)"
  echo "   (libraries par eio_main alcotest)"
  echo "   (modules <module_name>))"
  status=1
fi

if [[ -n "$MISSING_FILTERED" ]]; then
  echo "WARNING: module(s) registered in test/dune but not found in test/:"
  echo "$MISSING_FILTERED" | sed 's/^/  - /'
  echo
  status=1
fi

if [[ $status -eq 0 ]]; then
  count="$(echo "$ON_DISK" | grep -c . || true)"
  echo "OK: all $count test module(s) are wired into test/dune."
fi

if [[ $status -eq 1 && $STRICT -eq 0 ]]; then
  exit 0
fi
exit $status