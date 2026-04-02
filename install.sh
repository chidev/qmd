#!/usr/bin/env bash
set -euo pipefail
umask 022
shopt -s lastpipe 2>/dev/null || true

REPO_URL="${QMD_REPO_URL:-https://github.com/chidev/qmd.git}"
DEFAULT_REF="${QMD_INSTALL_REF:-feature/stabilize_qmd}"
INSTALL_DIR_DEFAULT="${QMD_INSTALL_DIR:-$HOME/.local/share/chidev-qmd}"
BIN_DIR_DEFAULT="${QMD_BIN_DIR:-$HOME/.local/bin}"
BIN_NAME="${QMD_BIN_NAME:-qmd}"
NO_PATH_UPDATE=0
FORCE=0
REF="$DEFAULT_REF"
INSTALL_DIR="$INSTALL_DIR_DEFAULT"
BIN_DIR="$BIN_DIR_DEFAULT"

blue=$'\033[34m'
green=$'\033[32m'
yellow=$'\033[33m'
red=$'\033[31m'
bold=$'\033[1m'
reset=$'\033[0m'

info() { printf "%s->%s %s\n" "$blue" "$reset" "$*"; }
ok() { printf "%sOK%s %s\n" "$green" "$reset" "$*"; }
warn() { printf "%sWARN%s %s\n" "$yellow" "$reset" "$*" >&2; }
err() { printf "%sERR%s %s\n" "$red" "$reset" "$*" >&2; }

usage() {
  cat <<EOF
${bold}chidev qmd installer${reset}

Installs the managed qmd fork and a stable wrapper executable.

Usage:
  install.sh [options]

Options:
  --ref REF              Git ref to install (default: ${DEFAULT_REF})
  --install-dir PATH     Managed clone path (default: ${INSTALL_DIR_DEFAULT})
  --bin-dir PATH         Wrapper install dir (default: ${BIN_DIR_DEFAULT})
  --bin-name NAME        Wrapper name (default: ${BIN_NAME})
  --force                Reset managed clone if it is dirty
  --no-path-update       Do not try to add bin dir to shell rc files
  -h, --help             Show this help

Environment:
  QMD_REPO_URL           Override git remote URL
  QMD_INSTALL_REF        Override default ref
  QMD_INSTALL_DIR        Override default install dir
  QMD_BIN_DIR            Override default bin dir
  QMD_BIN_NAME           Override wrapper name
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)
      REF="${2:?missing value for --ref}"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="${2:?missing value for --install-dir}"
      shift 2
      ;;
    --bin-dir)
      BIN_DIR="${2:?missing value for --bin-dir}"
      shift 2
      ;;
    --bin-name)
      BIN_NAME="${2:?missing value for --bin-name}"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --no-path-update)
      NO_PATH_UPDATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "required command not found: $1"
    exit 1
  fi
}

ensure_node() {
  need_cmd node
  local major
  major="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "${major:-0}" -lt 22 ]; then
    err "node >= 22 is required"
    exit 1
  fi
}

pick_package_manager() {
  if command -v bun >/dev/null 2>&1; then
    echo "bun"
  elif command -v npm >/dev/null 2>&1; then
    echo "npm"
  else
    err "bun or npm is required"
    exit 1
  fi
}

ensure_path_entry() {
  [ "$NO_PATH_UPDATE" -eq 1 ] && return 0
  case ":$PATH:" in
    *":$BIN_DIR:"*) return 0 ;;
  esac

  local line="export PATH=\"$BIN_DIR:\$PATH\""
  local shell_name rc
  shell_name="$(basename "${SHELL:-}")"
  case "$shell_name" in
    zsh) rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    *) rc="$HOME/.profile" ;;
  esac

  if [ -e "$rc" ] && ! [ -w "$rc" ]; then
    warn "cannot update $rc; add $BIN_DIR to PATH manually"
    return 0
  fi

  mkdir -p "$(dirname "$rc")"
  touch "$rc"
  if ! grep -F "$line" "$rc" >/dev/null 2>&1; then
    printf "\n%s\n" "$line" >>"$rc"
    ok "updated PATH in $rc"
  fi
}

sync_repo() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    info "updating managed clone in $INSTALL_DIR"
    git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
    if [ "$FORCE" -eq 1 ]; then
      git -C "$INSTALL_DIR" reset --hard HEAD
      git -C "$INSTALL_DIR" clean -fd
    elif [ -n "$(git -C "$INSTALL_DIR" status --porcelain)" ]; then
      err "managed clone is dirty: $INSTALL_DIR (re-run with --force)"
      exit 1
    fi
    git -C "$INSTALL_DIR" fetch origin "$REF" --depth 1
    git -C "$INSTALL_DIR" checkout -B "$REF" FETCH_HEAD
  else
    info "cloning $REPO_URL to $INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --depth 1 --branch "$REF" "$REPO_URL" "$INSTALL_DIR"
  fi
}

build_repo() {
  local pm="$1"
  info "building qmd with $pm"
  case "$pm" in
    bun)
      (cd "$INSTALL_DIR" && bun install --frozen-lockfile || bun install)
      (cd "$INSTALL_DIR" && bun run build)
      ;;
    npm)
      (cd "$INSTALL_DIR" && npm install)
      (cd "$INSTALL_DIR" && npm run build)
      ;;
  esac
}

clean_managed_clone() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" restore bun.lock 2>/dev/null || true
  fi
  rm -f "$INSTALL_DIR/package-lock.json"
}

install_wrapper() {
  local wrapper_path="$BIN_DIR/$BIN_NAME"
  info "installing wrapper to $wrapper_path"
  mkdir -p "$BIN_DIR"
  cat >"$wrapper_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
QMD_HOME="${INSTALL_DIR}"
exec node "\$QMD_HOME/dist/cli/qmd.js" "\$@"
EOF
  chmod 0755 "$wrapper_path"
}

verify_install() {
  local wrapper_path="$BIN_DIR/$BIN_NAME"
  info "verifying wrapper"
  "$wrapper_path" --version >/dev/null
  ok "verified $wrapper_path"
}

main() {
  info "installing managed qmd fork"
  need_cmd git
  ensure_node
  local pm
  pm="$(pick_package_manager)"
  sync_repo
  build_repo "$pm"
  clean_managed_clone
  install_wrapper
  ensure_path_entry
  verify_install
  ok "qmd installed from $REPO_URL @ $REF"
  printf "\n"
  printf "Managed clone: %s\n" "$INSTALL_DIR"
  printf "Wrapper:       %s/%s\n" "$BIN_DIR" "$BIN_NAME"
  printf "Ref:           %s\n" "$REF"
  case ":$PATH:" in
    *":$BIN_DIR:"*) printf "PATH:          ready\n" ;;
    *) printf "PATH:          add %s to PATH or open a new shell\n" "$BIN_DIR" ;;
  esac
}

main "$@"
