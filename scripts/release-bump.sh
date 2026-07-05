#!/usr/bin/env bash
# release-bump.sh — Bump PAR version following SemVer.
# Usage: release-bump.sh patch|minor|major|beta [bump_type] [--force]
#   release-bump.sh patch        → 0.4.0 → 0.4.1
#   release-bump.sh minor        → 0.4.0 → 0.5.0
#   release-bump.sh major        → 0.4.0 → 1.0.0
#   release-bump.sh beta minor   → 0.4.0 → 0.5.0-beta.20260613
#   release-bump.sh beta         → 0.4.0 → 0.4.1-beta.20260613 (default: patch)
#   --force                      → Skip Pre-Bump Gate (use only with explicit reason)
set -euo pipefail

cd "$(dirname "$0")/.."

# Parse --force flag
FORCE=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

# --- Pre-Bump Gate ---
if [ "$FORCE" = false ]; then
    # Check 1: Did public-facing files change since last version tag?
    LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    if [ -n "$LAST_TAG" ]; then
        CHANGED_PUBLIC=$(git diff --name-only "$LAST_TAG" -- lib/ bin/ bindings/ '*.mli' 2>/dev/null \
            | grep -v 'bindings/python/pyproject\.toml' \
            | grep -v 'bindings/python/par_runtime/__init__\.py' \
            | grep -v 'bindings/python/par_runtime/__init__\.pyi' || true)
        CHANGED_ALL=$(git diff --name-only "$LAST_TAG" 2>/dev/null || true)
        
        if [ -z "$CHANGED_PUBLIC" ] && [ -n "$CHANGED_ALL" ]; then
            echo "⚠️  PRE-BUMP GATE: No public-facing files (lib/, bin/, bindings/) changed since $LAST_TAG."
            echo "   Changed files:"
            git diff --name-only "$LAST_TAG" 2>/dev/null | sed 's/^/     /' || true
            echo ""
            echo "   This looks like a tooling/infra/docs-only change."
            echo "   → Refresh beta date only: sed -i ... dune-project && make sync-version"
            echo "   → Or use --force if you have an explicit reason."
            echo ""
            echo "   Aborting. Pre-Bump Gate failed (see project release rules)."
            exit 1
        fi
    fi

    # Check 2: Does the target version exist in ROADMAP?
    MODE_CHECK="${1:-patch}"
    BUMP_CHECK="${2:-patch}"
    
    CURRENT_CHECK=$(sed -n 's/^(version "\([^"]*\)")/\1/p' dune-project)
    BASE_CHECK=$(echo "$CURRENT_CHECK" | sed 's/-.*//')
    MA_C=$(echo "$BASE_CHECK" | cut -d. -f1)
    MI_C=$(echo "$BASE_CHECK" | cut -d. -f2)
    PA_C=$(echo "$BASE_CHECK" | cut -d. -f3)
    case "$MODE_CHECK" in
        patch) TARGET="v$MA_C.$MI_C.$((PA_C + 1))" ;;
        minor) TARGET="v$MA_C.$((MI_C + 1)).0" ;;
        major) TARGET="v$((MA_C + 1)).0.0" ;;
        beta)
            case "$BUMP_CHECK" in
                patch) TARGET="v$MA_C.$MI_C.$((PA_C + 1))" ;;
                minor) TARGET="v$MA_C.$((MI_C + 1)).0" ;;
                major) TARGET="v$((MA_C + 1)).0.0" ;;
            esac ;;
        *) TARGET="" ;;
    esac
    
    ROADMAP_MATCH=$(grep -rl "$TARGET" docs/v*-ROADMAP.md 2>/dev/null || true)
    if [ -n "$TARGET" ] && [ -n "$ROADMAP_MATCH" ]; then
        : # Found in ROADMAP, OK
    elif [ -n "$TARGET" ]; then
        echo "⚠️  PRE-BUMP GATE: Target version $TARGET not found in any docs/v*-ROADMAP.md."
        echo "   If this is intentional, use --force with a reason."
        echo "   Aborting. See docs/rules/release.md Pre-Bump Gate."
        exit 1
    fi
fi
# --- End Pre-Bump Gate ---

SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[a-zA-Z0-9._-]+)?$'

# Read current version from dune-project
CURRENT=$(sed -n 's/^(version "\([^"]*\)")/\1/p' dune-project)
if [ -z "$CURRENT" ]; then
    echo "ERROR: Cannot read version from dune-project" >&2
    exit 1
fi

# Strip pre-release suffix for base version
BASE=$(echo "$CURRENT" | sed 's/-.*//')

MA=$(echo "$BASE" | cut -d. -f1)
MI=$(echo "$BASE" | cut -d. -f2)
PA=$(echo "$BASE" | cut -d. -f3)

MODE="${1:-patch}"
BUMP="${2:-patch}"

case "$MODE" in
    patch)
        PA=$((PA + 1))
        NEW="$MA.$MI.$PA"
        ;;
    minor)
        MI=$((MI + 1))
        PA=0
        NEW="$MA.$MI.$PA"
        ;;
    major)
        MA=$((MA + 1))
        MI=0
        PA=0
        NEW="$MA.$MI.$PA"
        ;;
    beta)
        case "$BUMP" in
            patch) PA=$((PA + 1)) ;;
            minor) MI=$((MI + 1)); PA=0 ;;
            major) MA=$((MA + 1)); MI=0; PA=0 ;;
            *) echo "ERROR: Invalid bump type: $BUMP" >&2; exit 1 ;;
        esac
        TODAY=$(date +%Y%m%d)
        NEW="$MA.$MI.$PA-beta.$TODAY"
        ;;
    *)
        echo "ERROR: Invalid mode: $MODE (use patch|minor|major|beta)" >&2
        exit 1
        ;;
esac

# Validate new version
if ! echo "$NEW" | grep -qP "$SEMVER_RE"; then
    echo "ERROR: Invalid semver: $NEW" >&2
    exit 1
fi

# Apply
echo "Bumping: $CURRENT → $NEW"
sed -i "s/^(version \"[^\"]*\")/(version \"$NEW\")/" dune-project

# Sync to Python bindings
sed -i "s/^version = \".*\"/version = \"$NEW\"/" bindings/python/pyproject.toml
sed -i "s/^__version__ = \".*\"/__version__ = \"$NEW\"/" bindings/python/par_runtime/__init__.py

echo "OK Version bumped to $NEW"
