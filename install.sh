#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

GITHUB_REPO="jcz2020/par"
PREFIX="${PAR_INSTALL_PREFIX:-/usr/local}"
VERSION="${PAR_INSTALL_VERSION:-latest}"

detect_platform() {
  local arch="$(uname -m)"
  local os="$(uname -s)"
  case "$os" in
    Linux)
      case "$arch" in
        x86_64)  echo "linux-x64" ;;
        aarch64) echo "linux-arm64" ;;
        *)       die "Unsupported Linux arch: $arch" ;;
      esac ;;
    Darwin)
      case "$arch" in
        x86_64)  echo "macos-x64" ;;
        arm64)   echo "macos-arm64" ;;
        *)       die "Unsupported macOS arch: $arch" ;;
      esac ;;
    *) die "Unsupported OS: $os. Use scripts/build-from-source.sh" ;;
  esac
}

resolve_version() {
  if [ "$VERSION" = "latest" ]; then
    local api_response
    local api_url="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
    api_response=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api_url" 2>/dev/null) || true
    if [ -z "$api_response" ]; then
      api_response=$(curl -fsSL -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$GITHUB_REPO/tags?per_page=1" 2>/dev/null) || true
      if [ -n "$api_response" ]; then
        if command -v python3 >/dev/null 2>&1; then
          VERSION=$(echo "$api_response" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['name'])" 2>/dev/null) || true
        else
          VERSION=$(echo "$api_response" | grep '"name"' | head -1 | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"v([^"]+)".*/v\1/') || true
        fi
      fi
    else
      if command -v python3 >/dev/null 2>&1; then
        VERSION=$(echo "$api_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null) || true
      else
        VERSION=$(echo "$api_response" | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/') || true
      fi
    fi
    [ -n "$VERSION" ] || die "Failed to resolve latest version from GitHub (rate limited? set PAR_INSTALL_VERSION manually)"
  fi
  echo "${VERSION#v}"
}

sha512_checksum() {
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 512 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha512 "$1" | awk '{print $NF}'
  else
    die "No SHA-512 tool found (tried sha512sum, shasum, openssl)"
  fi
}

download_binary() {
  local platform="$1"
  local ver="$2"
  local tmpdir="$(mktemp -d)"
  local url="https://github.com/$GITHUB_REPO/releases/download/v${ver}/par-v${ver}-${platform}"
  local checksum_url="https://github.com/$GITHUB_REPO/releases/download/v${ver}/sha512-checksums.txt"

  info "Downloading PAR v${ver} for ${platform}..."
  if ! curl -fsSL -o "$tmpdir/par" "$url" 2>/dev/null; then
    rm -rf "$tmpdir"
    info "No prebuilt binary for ${platform}. Building from source..."
    build_from_source "$ver"
    return $?
  fi

  info "Downloading checksums..."
  if curl -fsSL -o "$tmpdir/checksums.txt" "$checksum_url" 2>/dev/null; then
    local expected="$(grep "par-v${ver}-${platform}" "$tmpdir/checksums.txt" | awk '{print $1}')"
    if [ -n "$expected" ]; then
      local actual="$(sha512_checksum "$tmpdir/par")"
      if [ "$expected" != "$actual" ]; then
        rm -rf "$tmpdir"
        die "SHA-512 checksum mismatch!\n  expected: $expected\n  actual:   $actual"
      fi
      info "Checksum verified"
    else
      warn "No checksum entry for par-v${ver}-${platform}, skipping verification"
    fi
  else
    warn "Checksums file not found, skipping verification"
  fi

  echo "$tmpdir"
}

build_from_source() {
  local ver="$1"
  command -v git >/dev/null 2>&1 || die "git not found (required for build-from-source)"
  command -v opam >/dev/null 2>&1 || die "opam not found (required for build-from-source). Install from https://opam.ocaml.org/doc/Install.html"

  local build_dir="$(mktemp -d)"
  if [ "$ver" = "latest" ] || ! git ls-remote --exit-code --heads "https://github.com/$GITHUB_REPO.git" "v${ver}" >/dev/null 2>&1; then
    info "Cloning PAR main branch (latest)..."
    git clone --depth 1 "https://github.com/$GITHUB_REPO.git" "$build_dir/par" || die "git clone failed"
  else
    info "Cloning PAR v${ver} source..."
    git clone --depth 1 --branch "v${ver}" "https://github.com/$GITHUB_REPO.git" "$build_dir/par" || die "git clone failed"
  fi

  cd "$build_dir/par"
  info "Installing dependencies (this may take a few minutes on first run)..."
  opam install . --deps-only -y 2>&1 | grep -v -i 'postgresql\|conf-postgresql\|pg_config\|No changes have been' >&2; true

  info "Building..."
  opam exec -- dune build bin/main.exe >&2 || die "Build failed"

  local tmpdir="$(mktemp -d)"
  cp _build/default/bin/main.exe "$tmpdir/par"
  cd - >/dev/null
  rm -rf "$build_dir"

  info "Build successful."
  echo "$tmpdir"
}

install_binary() {
  local tmpdir="$1"
  local target="$PREFIX/bin/par"

  if [ -w "$PREFIX/bin" ] 2>/dev/null; then
    install -m 755 "$tmpdir/par" "$target"
  else
    sudo install -d "$PREFIX/bin"
    sudo install -m 755 "$tmpdir/par" "$target"
  fi

  rm -rf "$tmpdir"
  info "Installed: $target"
}

main() {
  local platform
  platform="$(detect_platform)"
  local ver
  ver="$(resolve_version)"

  info "Installing PAR v${ver} (${platform}) to $PREFIX/bin"

  local tmpdir
  tmpdir="$(download_binary "$platform" "$ver")"
  install_binary "$tmpdir"

  info ""
  info "Installation complete. Run 'par --version' to verify."
  info "Quick start:"
  info "  par config"
  info "  par"
}

main
