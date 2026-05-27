#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

PREFIX="${1:-/usr/local}"

info "Installing PAR to $PREFIX/bin/par"

# --- System dependencies ---
detect_distro() {
  if [ -f /etc/debian_version ]; then echo "debian"
  elif [ -f /etc/fedora-release ]; then echo "fedora"
  elif [ -f /etc/arch-release ]; then echo "arch"
  elif [ -f /etc/alpine-release ]; then echo "alpine"
  else echo "unknown"
  fi
}

install_system_deps() {
  local distro=$(detect_distro)
  case "$distro" in
    debian)
      info "Installing system libraries (deb)..."
      sudo apt-get update -qq
      sudo apt-get install -y -qq build-essential git curl \
        libgmp-dev libsqlite3-dev libpq-dev libssl-dev pkg-config
      ;;
    fedora)
      info "Installing system libraries (rpm)..."
      sudo dnf install -y gcc make git curl \
        gmp-devel sqlite-devel libpq-devel openssl-devel pkg-config
      ;;
    arch)
      info "Installing system libraries (pacman)..."
      sudo pacman -S --noconfirm --needed base-devel git curl \
        gmp sqlite postgresql-libs openssl pkg-config
      ;;
    alpine)
      info "Installing system libraries (apk)..."
      sudo apk add build-base git curl \
        gmp-dev sqlite-dev postgresql-dev openssl-dev linux-headers
      ;;
    *)
      warn "Unknown distro. Please install manually: gcc, make, libgmp-dev, libsqlite3-dev, libpq-dev, libssl-dev"
      ;;
  esac
}

install_opam() {
  if command -v opam &>/dev/null; then
    info "opam already installed ($(opam --version))"
    return
  fi
  info "Installing opam..."
  bash -c "sh <(curl -fsSL https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh)"
  eval $(opam env)
}

setup_ocaml() {
  eval $(opam env 2>/dev/null || true)
  if ocaml --version 2>/dev/null | grep -q "5\."; then
    info "OCaml $(ocaml --version) already available"
    return
  fi
  info "Setting up OCaml 5.3.0 (this takes a few minutes)..."
  opam init --disable-sandboxing -y
  opam switch create . 5.3.0 -y || opam switch create . 5.4.1 -y
  eval $(opam env)
}

build_par() {
  eval $(opam env)
  info "Installing OCaml dependencies..."
  opam install . --deps-only -y
  info "Building PAR..."
  dune build
}

install_binary() {
  eval $(opam env)
  local bin="_build/default/bin/main.exe"
  [ -f "$bin" ] || die "Build failed - binary not found"
  sudo install -d "$DESTDIR$PREFIX/bin"
  sudo install -m 755 "$bin" "$DESTDIR$PREFIX/bin/par"
  info "Installed: $PREFIX/bin/par"
  info ""
  info "First run setup:"
  info "  par config"
  info "  par"
}

# --- Main ---
command -v gcc &>/dev/null || install_system_deps
command -v opam &>/dev/null || install_opam
setup_ocaml
build_par
install_binary
