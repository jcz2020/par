#!/usr/bin/env bash
# check_disclosure.sh — Block PRs that add forbidden partner identifiers.
#
# Enforces the disclosure rule in AGENTS.md: never record specific
# upstream/downstream project names, company names, or feedback-source
# identifiers in any committed artifact.
#
# Two-tier denylist:
# 1. PUBLIC_DENYLIST (hardcoded below) — generic placeholder, kept empty by
#    default. Add entries ONLY for identifiers that are safe to publish
#    (e.g. competitors mentioned in marketing). Real downstream partner
#    names must NOT be hardcoded here — see #2.
# 2. PRIVATE denylist via $DISCLOSURE_DENYLIST_EXTRA env var (one
#    identifier per line). For partner names that must never be committed.
#    CI injects via repo secret; locally, export the env var.
#    Example local use:
#      export DISCLOSURE_DENYLIST_EXTRA="partner-one
#      partner-two
#      specific-agent-name"
#
# Usage:
#   bash scripts/check_disclosure.sh                  # diff working tree vs HEAD
#   bash scripts/check_disclosure.sh --against=REF    # diff HEAD vs REF (CI mode)
#   bash scripts/check_disclosure.sh --all            # scan all tracked files
#   bash scripts/check_disclosure.sh path...          # restrict to paths
#   bash scripts/check_disclosure.sh --self-test      # run built-in fixtures
#
# Exit codes:
#   0 = clean, no forbidden identifiers found
#   1 = violations detected (CI should block merge)

set -euo pipefail

# ─── Public denylist ───────────────────────────────────────────────────
# Append with care. Each line is one identifier (case-insensitive substring match).
# Keep this empty by default — real partner identifiers go in
# $DISCLOSURE_DENYLIST_EXTRA (env var / CI secret). Listing them here would
# re-introduce them into the public repo, defeating the disclosure rule.
PUBLIC_DENYLIST=""

# ─── Private denylist (env var) ────────────────────────────────────────
PRIVATE_DENYLIST="${DISCLOSURE_DENYLIST_EXTRA:-}"

if [ -z "${DENYLIST+x}" ]; then
  DENYLIST="${PUBLIC_DENYLIST}
${PRIVATE_DENYLIST}"
fi

# ─── File filter ───────────────────────────────────────────────────────
# Whitelist of extensions to scan (others are skipped).
EXT_REGEX='\.(md|mli?|py|c|h|ya?ml|sh|toml|json|txt|opam|dune-project)$'
# Also always include files named exactly: dune-project, Makefile, AGENTS.md
SPECIAL_FILES='(^|/)(dune-project|Makefile|AGENTS.md|CHANGES.md|README.md)$'

# Paths to skip (build artifacts, vendored, internal-only).
SKIP_REGEX='(^|/)(_build|_opam|\.git|node_modules|__pycache__|\.beads|\.dolt|site|bindings/python/(build|dist)|\.opam|\.cache)/|^scripts/check_disclosure\.sh$'

# ─── Arg parsing ───────────────────────────────────────────────────────
MODE="working"          # default: working-tree diff vs HEAD
AGAINST=""              # set by --against=REF
PATHS=()

for arg in "$@"; do
  case "$arg" in
    --all)            MODE="all" ;;
    --against=*)      MODE="against"; AGAINST="${arg#--against=}" ;;
    --self-test)      run_self_test=1; ;;
    --help|-h)        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)              echo "Unknown flag: $arg" >&2; exit 2 ;;
    *)                PATHS+=("$arg") ;;
  esac
done
run_self_test="${run_self_test:-0}"

# ─── Helpers ───────────────────────────────────────────────────────────
should_scan() {
  # $1 = file path. Returns 0 (true) if file should be scanned.
  local f="$1"
  # Skip non-existent or deleted files
  [ -f "$f" ] || return 1
  # Skip excluded paths
  [[ "$f" =~ $SKIP_REGEX ]] && return 1
  # Match extension OR special-file list
  [[ "$f" =~ $EXT_REGEX ]] && return 0
  [[ "$f" =~ $SPECIAL_FILES ]] && return 0
  return 1
}

denylist_words() {
  # Print denylist, one word per line, skipping blanks and comments
  printf '%s\n' "$DENYLIST" | grep -vE '^[[:space:]]*(#|$)' || true
}

scan_text_for_violations() {
  # $1 = source label (file path)
  # stdin = text to scan
  # Sets global $violations count.
  local label="$1"
  local -a lines=()
  while IFS= read -r line; do
    lines+=("$line")
  done
  local word line lc_word lc_line
  while IFS= read -r word; do
    [ -z "$word" ] && continue
    lc_word="${word,,}"
    for line in "${lines[@]}"; do
      lc_line="${line,,}"
      if [[ "$lc_line" == *"$lc_word"* ]]; then
        echo "BLOCKED: $label: forbidden identifier '$word'"
        echo "  > ${line#"${line%%[![:space:]]*}"}"
        violations=$((violations + 1))
      fi
    done
  done < <(printf '%s\n' "$DENYLIST")
}

# ─── Scan modes ────────────────────────────────────────────────────────
violations=0

scan_added_lines_vs_ref() {
  local ref="$1"
  local current_file=""
  # git diff --unified=0 output:
  #   diff --git a/PATH b/PATH
  #   --- a/PATH
  #   +++ b/PATH
  #   @@ -X,Y +A,B @@ context
  #   +added line content
  while IFS= read -r line; do
    case "$line" in
      "+++ b/"*)
        current_file="${line#+++ b/}"
        ;;
      "+"*)
        [ "$line" = "+++" ] && continue
        local content="${line#+}"
        if [ -n "$current_file" ] && should_scan "$current_file"; then
          printf '%s\n' "$content" | scan_text_for_violations "$current_file"
        fi
        ;;
    esac
  done < <(git diff --unified=0 "$ref" -- "${PATHS[@]}" 2>/dev/null || true)
}

scan_all_files() {
  local f
  local -a files_to_scan=()
  if [ ${#PATHS[@]} -gt 0 ]; then
    for p in "${PATHS[@]}"; do
      if [ -d "$p" ]; then
        while IFS= read -r f; do
          files_to_scan+=("$f")
        done < <(find "$p" -type f 2>/dev/null)
      elif [ -f "$p" ]; then
        files_to_scan+=("$p")
      fi
    done
  else
    while IFS= read -r f; do
      files_to_scan+=("$f")
    done < <(git ls-files 2>/dev/null)
  fi
  for f in "${files_to_scan[@]}"; do
    should_scan "$f" || continue
    scan_text_for_violations "$f" < "$f"
  done
}

# ─── Self-test ─────────────────────────────────────────────────────────
run_self_test() {
  local tmpdir rc_passed=0 rc_failed=0
  tmpdir="$(mktemp -d)"

  echo "all good here, no violations" > "$tmpdir/clean.md"
  DENYLIST="acme-corp" bash "$0" --all "$tmpdir/clean.md" >/dev/null 2>&1 \
    && { echo "PASS: clean content → exit 0"; rc_passed=$((rc_passed+1)); } \
    || { echo "FAIL: clean content should not be flagged"; rc_failed=$((rc_failed+1)); }

  echo "discussion of acme-corp integration" > "$tmpdir/violation.md"
  DENYLIST="acme-corp" bash "$0" --all "$tmpdir/violation.md" >/dev/null 2>&1 \
    && { echo "FAIL: acme-corp should be flagged"; rc_failed=$((rc_failed+1)); } \
    || { echo "PASS: denylist match → exit 1"; rc_passed=$((rc_passed+1)); }

  echo "the ACME-CORP project" > "$tmpdir/upper.md"
  DENYLIST="acme-corp" bash "$0" --all "$tmpdir/upper.md" >/dev/null 2>&1 \
    && { echo "FAIL: uppercase ACME-CORP should be flagged"; rc_failed=$((rc_failed+1)); } \
    || { echo "PASS: case-insensitive match"; rc_passed=$((rc_passed+1)); }

  echo "zetacorp partnership" > "$tmpdir/zeta.md"
  DENYLIST="zetacorp" bash "$0" --all "$tmpdir/zeta.md" >/dev/null 2>&1 \
    && { echo "FAIL: env-var denylist should flag zetacorp"; rc_failed=$((rc_failed+1)); } \
    || { echo "PASS: env-var denylist works"; rc_passed=$((rc_passed+1)); }

  echo "acme-corp" > "$tmpdir/scratch.lock"
  DENYLIST="acme-corp" bash "$0" --all "$tmpdir/scratch.lock" >/dev/null 2>&1 \
    && { echo "PASS: non-whitelisted extension skipped"; rc_passed=$((rc_passed+1)); } \
    || { echo "FAIL: .lock should be skipped by extension filter"; rc_failed=$((rc_failed+1)); }

  echo "---"
  echo "Self-test: $rc_passed passed, $rc_failed failed"
  rm -rf "$tmpdir" 2>/dev/null || true
  [ "$rc_failed" -eq 0 ]
}

[ "$run_self_test" = "1" ] && run_self_test && exit 0 || [ "$run_self_test" = "1" ] && exit 1

# ─── Main ──────────────────────────────────────────────────────────────
case "$MODE" in
  working)
    # Working tree diff vs HEAD (uncommitted changes only)
    scan_added_lines_vs_ref "HEAD"
    ;;
  against)
    # Diff HEAD vs explicit ref (CI mode: --against=origin/main)
    if [ -z "$AGAINST" ]; then
      echo "ERROR: --against requires a ref argument" >&2
      exit 2
    fi
    scan_added_lines_vs_ref "$AGAINST"
    ;;
  all)
    scan_all_files
    ;;
esac

# ─── Report ────────────────────────────────────────────────────────────
if [ "$violations" -gt 0 ]; then
  echo ""
  echo "Disclosure check FAILED: $violations violation(s) found."
  echo "These identifiers must not appear in committed artifacts."
  echo "See AGENTS.md 'No Downstream Identifiable Information' for the rule,"
  echo "or docs/rules/disclosure.md for the full spec."
  echo ""
  echo "If this is a false positive (the word has a legitimate non-partner meaning),"
  echo "refactor to use a generic descriptor (e.g. 'a downstream project')."
  exit 1
fi

echo "Disclosure check passed: no forbidden identifiers in changes."
exit 0
