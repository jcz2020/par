#!/bin/bash
# PAR macOS-x64 release builder.
# Clone, compile, upload in one command on Intel Mac.
# Usage: bash scripts/build-macos-x64.sh [vX.Y.Z]
# No args = auto-detect latest release tag from GitHub.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
[[ "$(uname -m)" == "x86_64" ]] || die "Intel Mac only"
command -v gh &>/dev/null || die "gh CLI required: brew install gh"
gh auth status &>/dev/null || die "gh not authenticated: gh auth login"

if [[ -n "${1:-}" ]]; then
  TAG="$1"
else
  info "Auto-detecting latest release..."
  TAG="$(gh release list --repo jcz2020/par --limit 1 --json tagName --jq '.[0].tagName')"
  [[ -n "$TAG" ]] || die "No releases found"
fi

VERSION="${TAG#v}"
BINARY="par-${TAG}-macos-x64"
REPO="https://github.com/jcz2020/par.git"
WORKDIR="/tmp/par-build-macos-x64"

info "Building PAR $TAG for macOS-x64"

# --- Cleanup previous run ---
rm -rf "$WORKDIR"

# --- Clone at tag ---
info "Cloning $TAG..."
git clone --branch "$TAG" --depth 1 "$REPO" "$WORKDIR"
cd "$WORKDIR"

# --- opam setup ---
if ! command -v opam &>/dev/null; then
  info "Installing opam via Homebrew..."
  command -v brew &>/dev/null || die "Homebrew required: https://brew.sh"
  brew install opam
fi
eval "$(opam env 2>/dev/null || true)"

if ! ocaml --version 2>/dev/null | grep -qE '^OCaml 5\.[4-9]'; then
  info "Setting up OCaml 5.4.0..."
  opam init --disable-sandboxing -y 2>/dev/null || true
  opam switch create . ocaml-base-compiler.5.4.0 --no-install -y
  eval "$(opam env)"
fi

# --- Build (must match release.yml steps exactly) ---
# Only install par_cli deps, skip par_postgres (libpq keg-only issue)
info "Installing dependencies..."
opam install par_cli --deps-only -y

info "Compiling..."
opam exec -- dune build bin/main.exe

[[ -f _build/default/bin/main.exe ]] || die "Build failed"

info "Packaging..."
cp -f _build/default/bin/main.exe "$BINARY"
chmod +x "$BINARY"
strip "$BINARY" 2>/dev/null || true
shasum -a 512 "$BINARY" > "${BINARY}.sha512"

BINARY_SIZE="$(du -h "$BINARY" | cut -f1)"
info "Built: $BINARY ($BINARY_SIZE)"

# --- Upload ---
info "Uploading to GitHub Release $TAG..."
gh release upload "$TAG" "$BINARY" --clobber

info "Updating checksums..."
TMP="$(mktemp -d)"
if gh release download "$TAG" --pattern "sha512-checksums.txt" --dir "$TMP" --clobber 2>/dev/null; then
  grep -v "macos-x64" "$TMP/sha512-checksums.txt" > "$TMP/new.txt" || true
else
  touch "$TMP/new.txt"
fi
cat "${BINARY}.sha512" >> "$TMP/new.txt"
gh release upload "$TAG" "$TMP/new.txt" --clobber --name "sha512-checksums.txt"
rm -rf "$TMP"

# --- Cleanup ---
rm -rf "$WORKDIR"

info "Done — $BINARY uploaded to release $TAG"
