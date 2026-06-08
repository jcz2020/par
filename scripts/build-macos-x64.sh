#!/bin/bash
# Build PAR macOS-x64 binary on Intel Mac.
# Usage: bash scripts/build-macos-x64.sh [--upload]
#   --upload  Upload binary and updated checksums to the latest GitHub Release.
#
# Prerequisites: opam, OCaml 5.4+, gh CLI (for --upload)
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

UPLOAD=false
if [[ "${1:-}" == "--upload" ]]; then
  UPLOAD=true
fi

# --- Preflight checks ---
info "Preflight checks..."

ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
  die "This script builds macOS-x64 binaries. Current arch: $ARCH. Run on an Intel Mac."
fi

OS="$(uname -s)"
if [[ "$OS" != "Darwin" ]]; then
  die "This script is for macOS only. Current OS: $OS"
fi

command -v opam &>/dev/null || die "opam not found. Install from https://opam.ocaml.org/"
command -v dune &>/dev/null || die "dune not found. Run 'opam install dune' first."

eval "$(opam env 2>/dev/null || true)"

OCAML_VERSION="$(ocaml --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' || echo '0.0')"
OCAML_MAJOR="${OCAML_VERSION%%.*}"
OCAML_MINOR="${OCAML_VERSION#*.}"
if [[ "$OCAML_MAJOR" -lt 5 ]] || { [[ "$OCAML_MAJOR" -eq 5 ]] && [[ "$OCAML_MINOR" -lt 4 ]]; }; then
  die "OCaml 5.4+ required. Current: $(ocaml --version | head -1)"
fi

# --- Read version from dune-project ---
VERSION="$(grep -oP '(?<=\(version ")[^"]+' dune-project 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  die "Cannot read version from dune-project. Run from repo root."
fi
TAG="v${VERSION}"
BINARY="par-${TAG}-macos-x64"

info "Building PAR $TAG for macOS-x64"

# --- Build ---
info "Installing dependencies..."
opam install par_cli --deps-only -y

info "Compiling..."
opam exec -- dune build bin/main.exe

if [[ ! -f _build/default/bin/main.exe ]]; then
  die "Build failed — binary not found at _build/default/bin/main.exe"
fi

# --- Package ---
info "Stripping and renaming binary..."
cp -f _build/default/bin/main.exe "$BINARY"
chmod +x "$BINARY"
strip "$BINARY" 2>/dev/null || warn "strip failed (non-fatal)"

info "Generating SHA-512 checksum..."
shasum -a 512 "$BINARY" > "${BINARY}.sha512"

BINARY_SIZE="$(du -h "$BINARY" | cut -f1)"
info "Built: $BINARY ($BINARY_SIZE)"
info "Checksum: ${BINARY}.sha512"

# --- Upload ---
if [[ "$UPLOAD" == true ]]; then
  command -v gh &>/dev/null || die "gh CLI not found. Install from https://cli.github.com/"
  info "Uploading to GitHub Release $TAG..."
  gh release upload "$TAG" "$BINARY" --clobber
  info "Updating checksums file on release..."

  TMPDIR="$(mktemp -d)"
  gh release download "$TAG" --pattern "sha512-checksums.txt" --dir "$TMPDIR" --clobber 2>/dev/null || true

  if [[ -f "$TMPDIR/sha512-checksums.txt" ]]; then
    grep -v "macos-x64" "$TMPDIR/sha512-checksums.txt" > "$TMPDIR/sha512-checksums-new.txt" || true
  else
    touch "$TMPDIR/sha512-checksums-new.txt"
  fi
  cat "${BINARY}.sha512" >> "$TMPDIR/sha512-checksums-new.txt"
  gh release upload "$TAG" "$TMPDIR/sha512-checksums-new.txt" --clobber --name "sha512-checksums.txt"

  rm -rf "$TMPDIR"
  info "Upload complete!"
fi

echo ""
info "Done. Next steps:"
if [[ "$UPLOAD" == false ]]; then
  info "  1. Verify: ./$BINARY --version"
  info "  2. Upload: bash scripts/build-macos-x64.sh --upload"
fi
