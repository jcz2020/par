#!/usr/bin/env bash
# check_cjk_anchors.sh — Detect CJK anchor links that break under mkdocs slugifier.
#
# mkdocs-material strips non-ASCII characters when generating heading slugs.
# A link like [变量与上下文传播](#变量与上下文传播) will silently 404 because
# the actual slug becomes something like _9 (CJK stripped). This script
# catches such links before they reach production.
#
# Usage:
#   bash scripts/check_cjk_anchors.sh           # check docs/zh/
#   bash scripts/check_cjk_anchors.sh --strict  # exit 1 if any found
#
# Exit codes:
#   0 = no CJK anchor links found
#   1 = CJK anchor links found (strict mode)

set -euo pipefail

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --help|-h) sed -n '2,^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Search for markdown links whose anchor fragment contains non-ASCII chars.
# Pattern: ]( ... # <any non-ASCII> ... )
# Excludes http(s) URLs (external links are not slug-checked by mkdocs).
found=0

while IFS= read -r file; do
  # grep for lines with ](#... containing non-ASCII, excluding http links
  matches=$(grep -nP '\]\((?!https?://|#)[^)]*#[^)]*[^\x00-\x7F]' "$file" 2>/dev/null || true)
  # Also catch ](#<CJK> directly (in-page anchors)
  matches2=$(grep -nP '\]\(#[^)]*[^\x00-\x7F]' "$file" 2>/dev/null || true)
  # Also catch ](path#<CJK>) (cross-file anchors)
  matches3=$(grep -nP '\]\([^)#]*#[^)]*[^\x00-\x7F]' "$file" 2>/dev/null | grep -v 'https\?://' || true)

  combined="${matches}${matches2}${matches3}"
  if [ -n "$combined" ]; then
    [ $found -eq 0 ] && echo "::error::CJK anchor links break under mkdocs slugifier — use plain text (e.g. 「标题」) instead of [标题](#标题)"
    echo "  ✗ $file"
    echo "$combined" | sed 's/^/    /'
    found=$((found + 1))
  fi
done < <(find docs/zh/ -name '*.md' 2>/dev/null)

if [ $found -gt 0 ]; then
  echo ""
  echo "=== CJK Anchor Check: $found file(s) with broken CJK anchor links ==="
  echo "Fix: replace [text](#中文) with plain text like 「text」"
  echo "Reason: mkdocs slugifier strips CJK → anchor won't resolve"
  if [ $STRICT -eq 1 ]; then
    exit 1
  fi
else
  echo "=== CJK Anchor Check: PASS (0 broken CJK anchor links in docs/zh/) ==="
fi
