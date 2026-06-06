#!/usr/bin/env bash
set -euo pipefail

is_internal_doc() {
  case "$1" in
    docs/STRATEGY.md|docs/DESIGN.md|docs/release.md) return 0 ;;
    docs/v*-ROADMAP.md) return 0 ;;
    docs/plans/*) return 0 ;;
    docs/zh-CN/STRATEGY.md) return 0 ;;
  esac
  return 1
}

strip_code() {
  awk '
    BEGIN { c=0 }
    /^```/ { print ""; c=!c; next }
    /^~~~/ { print ""; c=!c; next }
    c { print ""; next }
    {
      while (match($0, /`[^`]*`/)) {
        $0 = substr($0, 1, RSTART-1) substr($0, RSTART+RLENGTH)
      }
      print
    }
  ' "$1"
}

is_external() {
  case "$1" in
    http://*|https://*|mailto:*|ftp://*) return 0 ;;
    \#*) return 0 ;;
  esac
  return 1
}

check_url() {
  local url="$1" dir="$2"
  is_external "$url" && return 0
  local target="${url%%\?*}"
  target="${target%%#*}"
  target="${target%/}"
  [[ -z "$target" ]] && return 0
  [[ -e "$dir/$target" ]] && return 0
  echo "BROKEN: $url"
  return 1
}

check_file() {
  local f=$1
  local dir
  dir=$(dirname "$f")
  local fail=0
  local line_num=0
  local text
  text=$(strip_code "$f")

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    local m url result
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      url="${m#*](}"
      url="${url%)}"
      [[ -z "$url" ]] && continue
      result=$(check_url "$url" "$dir" || true)
      if [[ "$result" == BROKEN* ]]; then
        echo "$f:$line_num: broken link -> $url"
        fail=1
      fi
    done < <(printf '%s' "$line" | grep -oE '!?\[[^]]*\]\([^)]+\)')

    if [[ "$line" =~ ^[[:space:]]{0,3}\[([^]]+)\]:[[:space:]]+([^[:space:]]+) ]]; then
      local ref_url="${BASH_REMATCH[2]}"
      result=$(check_url "$ref_url" "$dir" || true)
      if [[ "$result" == BROKEN* ]]; then
        echo "$f:$line_num: broken reference link -> $ref_url"
        fail=1
      fi
    fi
  done <<< "$text"

  return $fail
}

main() {
  local files=("$@")
  local rc=0
  if [ ${#files[@]} -eq 0 ]; then
    shopt -s globstar nullglob
    files=(README.md docs/**/*.md)
  fi
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    is_internal_doc "$f" && continue
    check_file "$f" || rc=1
  done
  exit "$rc"
}

main "$@"
