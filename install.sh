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
    api_response=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null) \
      || die "Failed to fetch release info from GitHub"
    if command -v python3 >/dev/null 2>&1; then
      VERSION=$(echo "$api_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)
    else
      VERSION=$(echo "$api_response" | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    fi
    [ -n "$VERSION" ] || die "Failed to resolve latest version from GitHub"
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
  curl -fsSL -o "$tmpdir/par" "$url" || die "Download failed: $url"

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
