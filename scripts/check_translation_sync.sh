#!/usr/bin/env bash
# check_translation_sync.sh — Check docs/ vs docs/zh/ bilingual translation sync.
#
# Scans English docs under docs/ and reports whether each has a corresponding
# Chinese translation under docs/zh/. For files that exist in both, compares
# git commit timestamps to detect stale translations.
#
# Usage:
#   bash scripts/check_translation_sync.sh            # report only (exit 0)
#   bash scripts/check_translation_sync.sh --strict   # exit 1 if missing/outdated
#
# Exit codes:
#   0 = all synced (or non-strict mode)
#   1 = missing or outdated translations found (strict mode only)

set -euo pipefail

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

EXCLUDE_PATTERNS=(
  "zh/"
  "archive/"
  "v*-ROADMAP.md"
  "STRATEGY.md"
  "DOC-MAINTENANCE.md"
  "rules/"
  "evaluations/"
  "plans/"
  "tutorials/04-multi-provider-fallback.md"
  "tutorials/05-session-resume.md"
  "RELEASE-TEMPLATE.md"
  "release*.md"
  "long-output*.md"
  "react-loop*.md"
)

should_skip() {
  local f="$1"
  for pat in "${EXCLUDE_PATTERNS[@]}"; do
    case "$pat" in
      */) # directory pattern: match if path starts with or contains the dir
        [[ "$f" == "$pat"* || "$f" == */"$pat"* ]] && return 0
        ;;
      *)
        # glob matching without quotes to allow * expansion
        [[ "$f" == $pat || "$f" == */$pat ]] && return 0
        ;;
    esac
  done
  return 1
}

synced=0
outdated=0
missing=0
total=0

while IFS= read -r en_file; do
  rel="${en_file#docs/}"
  should_skip "$rel" && continue
  [[ "$rel" != *.md ]] && continue

  total=$((total + 1))
  zh_file="docs/zh/$rel"

  if [ ! -f "$zh_file" ]; then
    echo "  ✗ MISSING  $en_file → $zh_file"
    missing=$((missing + 1))
    continue
  fi

  en_ts=$(git log -1 --format=%ct -- "$en_file" 2>/dev/null || echo 0)
  zh_ts=$(git log -1 --format=%ct -- "$zh_file" 2>/dev/null || echo 0)

  if [ "$en_ts" -gt "$zh_ts" ]; then
    echo "  ↓ OUTDATED $en_file (en newer than zh)"
    outdated=$((outdated + 1))
  else
    echo "  ✓ SYNCED   $en_file"
    synced=$((synced + 1))
  fi
done < <(find docs/ -maxdepth 1 -name '*.md' -type f; find docs/ -mindepth 2 -name '*.md' -type f | grep -v '^docs/zh/' | grep -v '^docs/archive/')

echo ""
echo "=== Translation Sync Summary ==="
echo "  Total English docs: $total"
echo "  ✓ Synced:   $synced"
echo "  ↓ Outdated: $outdated"
echo "  ✗ Missing:  $missing"

if [ "$total" -gt 0 ]; then
  pct=$(( (synced * 100) / total ))
  echo "  Sync rate:  ${pct}%"
fi

if [ "$STRICT" -eq 1 ] && [ $((missing + outdated)) -gt 0 ]; then
  echo ""
  echo "Translation sync check FAILED: $missing missing, $outdated outdated."
  exit 1
fi

echo ""
echo "Translation sync check passed."
exit 0
