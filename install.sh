#!/usr/bin/env bash
#
# PAR SDK installer wizard
#   curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
#   curl ... | bash -s -- --python --yes
#   curl ... | bash -s -- --ocaml --no-auto-setup
#
# Detects OS/arch, prompts Python vs OCaml, validates environment,
# optionally runs opam's official installer (to ~/.opam, no sudo) when
# the user confirms, then installs the chosen SDK variant and verifies.

set -euo pipefail

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi
info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
head()  { echo -e "\n${BLUE}${BOLD}── $* ──${NC}" >&2; }
ask()   { printf "${BOLD}%s${NC} [%s]: " "$1" "$2" >&2; }

GITHUB_REPO="jcz2020/par"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=8
MIN_OPAM_VERSION="2.1.0"
MIN_OCAML_VERSION="5.4"

TARGET=""
ASSUME_YES=0
AUTO_SETUP=1

while [ $# -gt 0 ]; do
  case "$1" in
    --python)    TARGET="python"; shift ;;
    --ocaml)     TARGET="ocaml"; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    --no-auto-setup) AUTO_SETUP=0; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//' | head -20
      exit 0 ;;
    *) err "Unknown option: $1. Use --help."; exit 1 ;;
  esac
done

detect_system() {
  OS="$(uname -s)"
  ARCH="$(uname -m)"
  case "$OS" in
    Linux)  OS_LABEL="Linux" ;;
    Darwin) OS_LABEL="macOS" ;;
    *) err "Unsupported OS: $OS"; exit 1 ;;
  esac
  case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) err "Unsupported arch: $ARCH"; exit 1 ;;
  esac
}

have_python() { command -v python3 >/dev/null 2>&1; }
have_pip()    { python3 -m pip --version >/dev/null 2>&1; }
have_opam()   { command -v opam >/dev/null 2>&1; }
have_ocaml()  { command -v ocaml >/dev/null 2>&1; }

python_version() {
  python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
}
opam_version()   { opam --version | head -1 | awk '{print $NF}'; }
ocaml_version()  { ocaml -version; }

# Returns 0 if $1 (actual) >= $2 (minimum), both X.Y form.
version_gte() {
  local actual="$1" min="$2"
  [ "$actual" = "$(printf '%s\n' "$actual\n$min" | sort -V | tail -1)" ]
}

confirm() {
  local prompt="$1" default="${2:-y}"
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  local ans
  if [ "$default" = "y" ]; then ask "$prompt" "Y/n"; else ask "$prompt" "y/N"; fi
  read -r ans
  case "${ans:-$default}" in
    [Yy]*) return 0 ;;
    *)     return 1 ;;
  esac
}

auto_setup_opam() {
  head "Auto-setup: installing opam"
  warn "Opam official installer will run. It installs to ~/.opam (no sudo)."
  warn "It will modify your shell init file (~/.bashrc or ~/.zshrc) to add opam to PATH."
  if ! confirm "Proceed with opam auto-install?"; then
    err "Aborted. Install opam manually: https://opam.ocaml.org/doc/Install.html"
    exit 1
  fi
  local tmp; tmp="$(mktemp -d)"
  info "Downloading opam installer..."
  curl -fSL --proto '=https' https://opam.ocaml.org/install -o "$tmp/opam_installer.sh"
  bash "$tmp/opam_installer.sh" --no-backup --no-setup 2>&1 | tail -20
  rm -rf "$tmp"
  # Source opam env so subsequent opam/ocaml calls in THIS shell work.
  if [ -f "$HOME/.opam/opam-init/init.zsh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.opam/opam-init/init.zsh" >/dev/null 2>&1 || true
  elif [ -f "$HOME/.opam/opam-init/init.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.opam/opam-init/init.sh" >/dev/null 2>&1 || true
  fi
  export PATH="$HOME/.opam/bin:$PATH"
  have_opam || { err "opam still not found after install"; exit 1; }
  info "Opam $(opam_version) installed."
}

validate_python() {
  head "Validating Python environment"
  if ! have_python; then
    err "Python 3 not found."
    err "Install Python 3.${MIN_PYTHON_MINOR}+ manually (https://python.org) and re-run."
    exit 1
  fi
  local ver; ver="$(python_version)"
  info "Python: $ver"
  if ! version_gte "$ver" "${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}"; then
    err "Python $ver < required ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}."
    exit 1
  fi
  if ! have_pip; then
    err "pip not found. Install with: python3 -m ensurepip"
    exit 1
  fi
  info "pip: $(python3 -m pip --version 2>&1 | head -1)"
  info "Python environment OK."
}

validate_ocaml() {
  head "Validating OCaml environment"
  if ! have_opam; then
    if [ "$AUTO_SETUP" = 1 ]; then
      auto_setup_opam
    else
      err "opam not found and --no-auto-setup was passed."
      err "Install manually: https://opam.ocaml.org/doc/Install.html"
      exit 1
    fi
  fi
  local opam_v; opam_v="$(opam_version)"
  info "opam: $opam_v"
  if ! version_gte "$opam_v" "$MIN_OPAM_VERSION"; then
    err "opam $opam_v < required $MIN_OPAM_VERSION"
    exit 1
  fi
  local ocaml_v
  if have_ocaml; then
    ocaml_v="$(ocaml_version | awk -F'+' '{print $1}')"
    info "OCaml: $ocaml_v"
    if ! version_gte "$ocaml_v" "$MIN_OCAML_VERSION"; then
      warn "OCaml $ocaml_v < $MIN_OCAML_VERSION. Creating switch with $MIN_OCAML_VERSION..."
      opam switch create par "${MIN_OCAML_VERSION}"
      eval "$(opam env --switch=par)"
    fi
  else
    warn "No OCaml switch found. Creating one with $MIN_OCAML_VERSION..."
    opam switch create par "${MIN_OCAML_VERSION}"
    eval "$(opam env --switch=par)"
    ocaml_v="$(ocaml_version | awk -F'+' '{print $1}')"
    info "OCaml: $ocaml_v"
  fi
  eval "$(opam env --switch=par)"
  info "OCaml environment OK."
}

install_python() {
  head "Installing par-runtime (Python)"
  python3 -m pip install --user --upgrade par-runtime
  info "par-runtime installed."
}

install_ocaml() {
  head "Installing par (OCaml)"
  eval "$(opam env --switch=par)"
  opam install -y par
  info "par installed (opam switch: par)."
}

verify_python() {
  head "Verifying par-runtime import"
  python3 -c "from par_runtime import Runtime; r = Runtime('{\"persistence\": [\"Sqlite\", \":memory:\"]}'); r.close(); print('OK')"
}

verify_ocaml() {
  head "Verifying par (opam switch)"
  eval "$(opam env --switch=par)"
  opam list --installed par
}

main() {
  head "PAR SDK installer"
  info "Detecting system..."
  detect_system
  info "OS: $OS_LABEL ($OS)  Arch: $ARCH"

  head "Choose SDK variant"
  if [ -z "$TARGET" ]; then
    echo -e "  ${BOLD}1)${NC} Python  (par-runtime via pip)  — recommended for Python backend devs" >&2
    echo -e "  ${BOLD}2)${NC} OCaml   (par via opam)            — recommended for OCaml devs" >&2
    ask "Select" "1"
    read -r choice
    case "$choice" in
      1|py|python|"") TARGET="python" ;;
      2|oc|ocaml)      TARGET="ocaml"  ;;
      *) err "Invalid choice"; exit 1 ;;
    esac
  fi
  info "Selected: $TARGET"

  case "$TARGET" in
    python)
      validate_python
      install_python
      verify_python
      ;;
    ocaml)
      validate_ocaml
      install_ocaml
      verify_ocaml
      ;;
  esac

  head "PAR SDK installed successfully"
  cat <<EOF >&2

Get started:
EOF
  case "$TARGET" in
    python)
      cat <<'EOF' >&2
  Python:
    >>> from par_runtime import Runtime
    >>> rt = Runtime('{"persistence": ["Sqlite", ":memory:"]}')
EOF
      ;;
    ocaml)
      cat <<'EOF' >&2
  OCaml (in switch 'par'):
    opam switch set par
    dune init proj my-agent && cd my-agent
    # add par to your dune-project deps, then:
    open Par
    Eio_main.run (fun _ -> ...)
EOF
      ;;
  esac
  cat <<EOF >&2

Docs: https://jcz2020.github.io/par
Repo: https://github.com/${GITHUB_REPO}
EOF
}

main
