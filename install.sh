#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DEFAULT="RobertFlexx/fastfind"
DEFAULT_SYSTEM_PREFIX="/usr/local"
DEFAULT_USER_PREFIX="${HOME}/.local"
PRIMARY_NAME="fastfind"
SECONDARY_NAME="ff"
PRIMARY_MANPAGE="fastfind.1"
SECONDARY_MANPAGE="ff.1"
MAN_SOURCE_PATH="mandoc/ff.1"
USER_AGENT="fastfind-installer"

QUIET=0
INSTALL_MANPAGES=1
FORCE_LOCAL=0
PREFIX_EXPLICIT=0
BIN_DIR_EXPLICIT=0
MAN_DIR_EXPLICIT=0

REPO="${REPO:-$REPO_DEFAULT}"
REQUESTED_TAG=""
PREFIX="$DEFAULT_SYSTEM_PREFIX"
BIN_DIR=""
MAN_DIR=""
OS=""
ARCH=""
KERNEL_RAW=""
DISTRO_NAME=""
DISTRO_VERSION=""
DISTRO_CODENAME=""
PLATFORM_LABEL=""
DOWNLOADER=""
ROOT_CMD=""
USE_ROOT_CMD=0
WORKDIR=""
TMP_BIN=""
TMP_MAN=""
VERSION=""
USE_LATEST_REDIRECT=0
RELEASE_JSON=""

supports_color() {
  [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]
}

if supports_color; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_MAGENTA=""
  C_CYAN=""
fi

line() {
  printf "%s\n" "────────────────────────────────────────────────────────────"
}

print_msg() {
  [ "$QUIET" -eq 1 ] && return 0
  printf "%b\n" "$1"
}

step() {
  print_msg "${C_CYAN}->${C_RESET} $1"
}

okay() {
  print_msg "${C_GREEN}✓${C_RESET} $1"
}

note() {
  print_msg "${C_BLUE}•${C_RESET} $1"
}

warn() {
  printf "%b\n" "${C_YELLOW}!${C_RESET} $1" >&2
}

die() {
  printf "%b\n" "${C_RED}x${C_RESET} $1" >&2
  exit 1
}

on_error() {
  local code="$1" line_no="$2" cmd="$3"
  [ "$code" -eq 0 ] && return 0
  die "failed at line ${line_no}: ${cmd}"
}

cleanup() {
  [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
}

trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT INT TERM

usage() {
  cat <<EOF
${C_BOLD}fastfind installer${C_RESET}

Install prebuilt binaries from GitHub releases.

Usage:
  install.sh [options]

Options:
  --repo <owner/repo>     GitHub repo to install from (default: ${REPO_DEFAULT})
  --tag <tag>             Install a specific release tag
  --version <tag>         Same as --tag
  --prefix <dir>          Installation prefix
  --bin-dir <dir>         Binary directory
  --man-dir <dir>         Manpage directory
  --no-man                Skip manpage installation
  --force-local           Force install into ${DEFAULT_USER_PREFIX}
  -q, --quiet             Reduce output
  -h, --help              Show this help

Examples:
  curl -fsSL https://raw.githubusercontent.com/${REPO_DEFAULT}/main/install.sh | bash
  bash install.sh --tag v2.1.0
  bash install.sh --force-local
EOF
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

releases_page_url() {
  printf "https://github.com/%s/releases\n" "$REPO"
}

nearest_existing_parent() {
  local path="$1"
  while [ ! -e "$path" ] && [ "$path" != "/" ]; do
    path="$(dirname "$path")"
  done
  printf "%s\n" "$path"
}

path_writable_or_creatable() {
  local path="$1"
  local base=""
  if [ -e "$path" ]; then
    [ -w "$path" ]
    return
  fi
  base="$(nearest_existing_parent "$path")"
  [ -w "$base" ]
}

path_exists_any() {
  [ -e "$1" ] || [ -L "$1" ]
}

path_in_env() {
  local needle="$1"
  case ":$PATH:" in
    *":$needle:"*) return 0 ;;
    *) return 1 ;;
  esac
}

read_os_release() {
  local file=""
  if [ -r /etc/os-release ]; then
    file="/etc/os-release"
  elif [ -r /usr/lib/os-release ]; then
    file="/usr/lib/os-release"
  fi

  [ -n "$file" ] || return 0

  DISTRO_NAME="$(awk -F= '$1=="NAME"{gsub(/^"|"$/, "", $2); print $2}' "$file")"
  DISTRO_VERSION="$(awk -F= '$1=="VERSION_ID"{gsub(/^"|"$/, "", $2); print $2}' "$file")"
  DISTRO_CODENAME="$(awk -F= '$1=="VERSION_CODENAME"{gsub(/^"|"$/, "", $2); print $2}' "$file")"

  if [ -z "$DISTRO_CODENAME" ]; then
    DISTRO_CODENAME="$(awk -F= '$1=="UBUNTU_CODENAME"{gsub(/^"|"$/, "", $2); print $2}' "$file")"
  fi
}

detect_platform() {
  KERNEL_RAW="$(uname -s 2>/dev/null || true)"
  case "$(printf "%s" "$KERNEL_RAW" | tr '[:upper:]' '[:lower:]')" in
    linux) OS="linux" ;;
    darwin) OS="darwin" ;;
    freebsd) OS="freebsd" ;;
    openbsd) OS="openbsd" ;;
    netbsd) OS="netbsd" ;;
    *) die "unsupported operating system: ${KERNEL_RAW:-unknown}" ;;
  esac

  case "$(uname -m 2>/dev/null || true)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7) ARCH="arm" ;;
    i386|i686) ARCH="386" ;;
    *) die "unsupported architecture: $(uname -m 2>/dev/null || printf unknown)" ;;
  esac

  if [ "$OS" = "linux" ]; then
    read_os_release
    if [ -n "$DISTRO_NAME" ] && [ -n "$DISTRO_VERSION" ]; then
      PLATFORM_LABEL="${DISTRO_NAME} ${DISTRO_VERSION} (${OS}/${ARCH})"
    elif [ -n "$DISTRO_NAME" ]; then
      PLATFORM_LABEL="${DISTRO_NAME} (${OS}/${ARCH})"
    else
      PLATFORM_LABEL="Linux (${OS}/${ARCH})"
    fi
    if [ -n "$DISTRO_CODENAME" ]; then
      PLATFORM_LABEL="${PLATFORM_LABEL} ${C_DIM}[${DISTRO_CODENAME}]${C_RESET}"
    fi
  elif [ "$OS" = "darwin" ]; then
    local mac_ver=""
    mac_ver="$(sw_vers -productVersion 2>/dev/null || true)"
    if [ -n "$mac_ver" ]; then
      PLATFORM_LABEL="macOS ${mac_ver} (${OS}/${ARCH})"
    else
      PLATFORM_LABEL="macOS (${OS}/${ARCH})"
    fi
  else
    PLATFORM_LABEL="${KERNEL_RAW} (${OS}/${ARCH})"
  fi
}

detect_downloader() {
  if has_cmd curl; then
    DOWNLOADER="curl"
  elif has_cmd wget; then
    DOWNLOADER="wget"
  else
    die "curl or wget is required"
  fi
}

detect_root_cmd() {
  if [ "$(id -u)" -eq 0 ]; then
    ROOT_CMD=""
    return 0
  fi

  if has_cmd doas; then
    ROOT_CMD="doas"
  elif has_cmd sudo; then
    ROOT_CMD="sudo"
  else
    ROOT_CMD=""
  fi
}

fetch_text() {
  local url="$1"
  case "$DOWNLOADER" in
    curl)
      curl -fsSL --retry 3 --retry-delay 1 --retry-all-errors -A "$USER_AGENT" "$url"
      ;;
    wget)
      wget -qO- --user-agent="$USER_AGENT" "$url"
      ;;
  esac
}

download_file() {
  local url="$1"
  local dest="$2"
  case "$DOWNLOADER" in
    curl)
      curl -fsSL --retry 3 --retry-delay 1 --retry-all-errors -A "$USER_AGENT" -o "$dest" "$url"
      ;;
    wget)
      wget -qO "$dest" --user-agent="$USER_AGENT" "$url"
      ;;
  esac
}

detect_libc() {
  if [ "$OS" != "linux" ]; then
    return 0
  fi

  local libc_check=""
  libc_check="$(ldd --version 2>&1 | head -1 || true)"
  if printf "%s" "$libc_check" | grep -qi musl; then
    printf "musl\n"
  else
    printf "glibc\n"
  fi
}

extract_tag_name() {
  local json="${1:-}"
  if [ -z "$json" ]; then
    json="$(cat || true)"
  fi
  printf "%s" "$json" | tr -d '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

extract_browser_download_urls() {
  printf "%s" "$1" | grep -oE 'https://github\.com/[^"]+/releases/download/[^"]+' | sort -u
}

arch_token_matches() {
  local base="$1"
  case "$ARCH" in
    amd64) printf "%s" "$base" | grep -qiE '(amd64|x86_64)' ;;
    arm64) printf "%s" "$base" | grep -qiE '(arm64|aarch64)' ;;
    arm) printf "%s" "$base" | grep -qiE '(armv7|armv7l|armhf)' ;;
    386) printf "%s" "$base" | grep -qiE '(386|i686|i386)' ;;
    *) return 1 ;;
  esac
}

os_token_matches() {
  local base="$1"
  case "$OS" in
    linux) printf "%s" "$base" | grep -qi 'linux' ;;
    darwin) printf "%s" "$base" | grep -qiE '(darwin|macos|osx)' ;;
    freebsd) printf "%s" "$base" | grep -qi 'freebsd' ;;
    openbsd) printf "%s" "$base" | grep -qi 'openbsd' ;;
    netbsd) printf "%s" "$base" | grep -qi 'netbsd' ;;
    *) return 1 ;;
  esac
}

score_release_asset_url() {
  local url="$1" libc="$2"
  local base=""
  local score=500

  base="$(printf "%s" "${url##*/}" | tr '[:upper:]' '[:lower:]')"

  os_token_matches "$base" || return 1
  arch_token_matches "$base" || return 1

  case "$base" in
    *.deb|*.rpm|*.tar*|*.zip|*.gz|*.sha256|*.asc|*.txt|*.json) return 1 ;;
  esac

  if [ "$OS" = "linux" ]; then
    if [ "$libc" = "musl" ]; then
      case "$base" in
        *musl*) score=$((score - 200)) ;;
        *glibc*) score=$((score + 200)) ;;
        *) score=$((score - 50)) ;;
      esac
    else
      case "$base" in
        *glibc*) score=$((score - 200)) ;;
        *musl*) score=$((score + 150)) ;;
        *) score=$((score - 100)) ;;
      esac
    fi
  fi

  if printf "%s" "$base" | grep -qi "${SECONDARY_NAME}-"; then
    score=$((score - 20))
  fi

  printf "%s\t%s\n" "$score" "$url"
}

order_urls_by_release_score() {
  local json="$1"
  local libc="$2"
  local url=""
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    score_release_asset_url "$url" "$libc" || true
  done <<< "$(extract_browser_download_urls "$json")" | LC_ALL=C sort -n | cut -f2-
}

synthetic_binary_urls() {
  local libc="$1"
  local vn="$VERSION"
  if [ "$USE_LATEST_REDIRECT" -eq 1 ]; then
    vn="latest"
  fi

  if [ "$OS" = "linux" ]; then
    for base in "$SECONDARY_NAME" "$PRIMARY_NAME"; do
      printf "%s\n" "https://github.com/${REPO}/releases/download/${vn}/${base}-linux-${libc}-${ARCH}"
      printf "%s\n" "https://github.com/${REPO}/releases/download/${vn}/${base}-linux-${ARCH}"
      if [ "$USE_LATEST_REDIRECT" -eq 1 ]; then
        printf "%s\n" "https://github.com/${REPO}/releases/latest/download/${base}-linux-${libc}-${ARCH}"
        printf "%s\n" "https://github.com/${REPO}/releases/latest/download/${base}-linux-${ARCH}"
      fi
    done
  else
    for base in "$SECONDARY_NAME" "$PRIMARY_NAME"; do
      printf "%s\n" "https://github.com/${REPO}/releases/download/${vn}/${base}-${OS}-${ARCH}"
      if [ "$USE_LATEST_REDIRECT" -eq 1 ]; then
        printf "%s\n" "https://github.com/${REPO}/releases/latest/download/${base}-${OS}-${ARCH}"
      fi
    done
  fi
}

list_binary_download_urls_ordered() {
  local libc=""
  libc="$(detect_libc)"

  if [ -n "$RELEASE_JSON" ]; then
    order_urls_by_release_score "$RELEASE_JSON" "$libc"
  fi

  synthetic_binary_urls "$libc" | awk '!seen[$0]++'
}

resolve_release() {
  RELEASE_JSON=""
  USE_LATEST_REDIRECT=0

  local api_url=""
  local json=""
  local tag=""

  if [ -n "$REQUESTED_TAG" ]; then
    api_url="https://api.github.com/repos/${REPO}/releases/tags/$(printf "%s" "$REQUESTED_TAG" | sed "s/'/%27/g")"
  else
    api_url="https://api.github.com/repos/${REPO}/releases/latest"
  fi

  if json="$(fetch_text "$api_url" 2>/dev/null)"; then
    RELEASE_JSON="$json"
    tag="$(extract_tag_name "$json")"
    if [ -n "$tag" ]; then
      VERSION="$tag"
    elif [ -n "$REQUESTED_TAG" ]; then
      VERSION="$REQUESTED_TAG"
    fi
  elif [ -n "$REQUESTED_TAG" ]; then
    VERSION="$REQUESTED_TAG"
  fi

  if [ -z "$VERSION" ]; then
    VERSION="${REQUESTED_TAG:-latest}"
  fi

  if [ -z "$RELEASE_JSON" ] && [ -z "$REQUESTED_TAG" ]; then
    USE_LATEST_REDIRECT=1
    VERSION="latest"
    warn "could not fetch GitHub release metadata; trying latest redirect download URLs"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        shift
        [ "$#" -gt 0 ] || die "--repo requires a value"
        REPO="$1"
        ;;
      --tag|--version)
        local veropt="$1"
        shift
        [ "$#" -gt 0 ] || die "${veropt} requires a value"
        REQUESTED_TAG="$1"
        ;;
      --prefix)
        shift
        [ "$#" -gt 0 ] || die "--prefix requires a value"
        PREFIX="$1"
        PREFIX_EXPLICIT=1
        ;;
      --bin-dir)
        shift
        [ "$#" -gt 0 ] || die "--bin-dir requires a value"
        BIN_DIR="$1"
        BIN_DIR_EXPLICIT=1
        ;;
      --man-dir)
        shift
        [ "$#" -gt 0 ] || die "--man-dir requires a value"
        MAN_DIR="$1"
        MAN_DIR_EXPLICIT=1
        ;;
      --no-man)
        INSTALL_MANPAGES=0
        ;;
      --force-local)
        FORCE_LOCAL=1
        ;;
      -q|--quiet)
        QUIET=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
    shift
  done
}

apply_user_prefix() {
  PREFIX="$DEFAULT_USER_PREFIX"
  if [ "$BIN_DIR_EXPLICIT" -eq 0 ]; then
    BIN_DIR="${PREFIX}/bin"
  fi
  if [ "$MAN_DIR_EXPLICIT" -eq 0 ]; then
    case "$OS" in
      openbsd|freebsd|netbsd) MAN_DIR="${PREFIX}/man/man1" ;;
      *) MAN_DIR="${PREFIX}/share/man/man1" ;;
    esac
  fi
}

finalize_paths() {
  if [ "$FORCE_LOCAL" -eq 1 ]; then
    apply_user_prefix
  else
    [ -n "$BIN_DIR" ] || BIN_DIR="${PREFIX}/bin"
    if [ -z "$MAN_DIR" ]; then
      case "$OS" in
        openbsd|freebsd|netbsd) MAN_DIR="${PREFIX}/man/man1" ;;
        *) MAN_DIR="${PREFIX}/share/man/man1" ;;
      esac
    fi
  fi
}

needs_privilege() {
  if ! path_writable_or_creatable "$BIN_DIR"; then
    return 0
  fi
  if [ "$INSTALL_MANPAGES" -eq 1 ] && ! path_writable_or_creatable "$MAN_DIR"; then
    return 0
  fi
  return 1
}

decide_install_mode() {
  if [ "$(id -u)" -eq 0 ]; then
    USE_ROOT_CMD=0
    return 0
  fi

  if ! needs_privilege; then
    USE_ROOT_CMD=0
    return 0
  fi

  if [ -n "$ROOT_CMD" ]; then
    USE_ROOT_CMD=1
    return 0
  fi

  if [ "$FORCE_LOCAL" -eq 0 ] && [ "$PREFIX_EXPLICIT" -eq 0 ] && [ "$BIN_DIR_EXPLICIT" -eq 0 ] && [ "$MAN_DIR_EXPLICIT" -eq 0 ]; then
    warn "system install needs elevated privileges, falling back to ${DEFAULT_USER_PREFIX}"
    apply_user_prefix
    USE_ROOT_CMD=0
    return 0
  fi

  die "installation target needs elevated privileges and neither sudo nor doas is available"
}

run_fs() {
  if [ "$USE_ROOT_CMD" -eq 1 ]; then
    "$ROOT_CMD" "$@"
  else
    "$@"
  fi
}

ensure_dir() {
  local dir="$1"
  [ -d "$dir" ] || run_fs mkdir -p "$dir"
}

prepare_workspace() {
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/fastfind-installer.XXXXXX")"
  TMP_BIN="${WORKDIR}/${SECONDARY_NAME}"
  TMP_MAN="${WORKDIR}/${SECONDARY_MANPAGE}"
}

render_header() {
  [ "$QUIET" -eq 1 ] && return 0
  line
  printf "%b\n" "${C_BOLD}${C_MAGENTA}fastfind installer${C_RESET}"
  printf "%b\n" "${C_DIM}repo:${C_RESET}   ${REPO}"
  printf "%b\n" "${C_DIM}target:${C_RESET} ${BIN_DIR}"
  if [ "$INSTALL_MANPAGES" -eq 1 ]; then
    printf "%b\n" "${C_DIM}man:${C_RESET}    ${MAN_DIR}"
  fi
  printf "%b\n" "${C_DIM}host:${C_RESET}   ${PLATFORM_LABEL}"
  printf "%b\n" "${C_DIM}releases:${C_RESET} $(releases_page_url)"
  line
}

download_binary() {
  local url=""
  local tried=0

  step "downloading ${SECONDARY_NAME} for ${OS}/${ARCH}"

  while IFS= read -r url; do
    [ -n "$url" ] || continue
    tried=1
    if download_file "$url" "$TMP_BIN" 2>/dev/null && [ -s "$TMP_BIN" ]; then
      chmod 755 "$TMP_BIN"
      okay "binary downloaded"
      return 0
    fi
  done <<< "$(list_binary_download_urls_ordered)"

  if [ "$tried" -eq 0 ]; then
    die "no candidate download URLs were generated for ${PLATFORM_LABEL}. See $(releases_page_url)"
  fi

  die "failed to download a matching release asset for ${PLATFORM_LABEL}. See $(releases_page_url)"
}

download_manpage() {
  [ "$INSTALL_MANPAGES" -eq 1 ] || return 0

  local url=""
  local refs=""

  if [ "$USE_LATEST_REDIRECT" -eq 1 ]; then
    refs="main"
  else
    refs="${VERSION} main"
  fi

  step "downloading manpage"

  for ref in $refs; do
    url="https://raw.githubusercontent.com/${REPO}/${ref}/${MAN_SOURCE_PATH}"
    if download_file "$url" "$TMP_MAN" 2>/dev/null && [ -s "$TMP_MAN" ]; then
      okay "manpage downloaded"
      return 0
    fi
  done

  warn "manpage was not found, skipping manual page installation"
  INSTALL_MANPAGES=0
}

backup_conflicting_alias() {
  local path="$1"
  local desired_target="$2"
  local backup=""

  if ! path_exists_any "$path"; then
    return 0
  fi

  if [ -L "$path" ] && [ "$(readlink "$path" 2>/dev/null || true)" = "$desired_target" ]; then
    return 0
  fi

  backup="${path}.backup.$(date +%Y%m%d%H%M%S)"
  warn "backing up existing $(basename "$path") to $(basename "$backup")"
  run_fs mv "$path" "$backup"
}

install_binary() {
  local primary_path="${BIN_DIR}/${PRIMARY_NAME}"
  local secondary_path="${BIN_DIR}/${SECONDARY_NAME}"

  step "installing binary"
  ensure_dir "$BIN_DIR"
  run_fs install -m 755 "$TMP_BIN" "$primary_path"
  backup_conflicting_alias "$secondary_path" "$PRIMARY_NAME"
  run_fs rm -f "$secondary_path"
  run_fs ln -s "$PRIMARY_NAME" "$secondary_path"
  okay "installed ${PRIMARY_NAME} and ${SECONDARY_NAME}"
}

install_manpages() {
  [ "$INSTALL_MANPAGES" -eq 1 ] || return 0

  local primary_man="${MAN_DIR}/${PRIMARY_MANPAGE}"
  local secondary_man="${MAN_DIR}/${SECONDARY_MANPAGE}"

  step "installing manpages"
  ensure_dir "$MAN_DIR"
  run_fs install -m 644 "$TMP_MAN" "$secondary_man"
  run_fs install -m 644 "$TMP_MAN" "$primary_man"
  okay "installed manpages for man ${SECONDARY_NAME} and man ${PRIMARY_NAME}"
}

refresh_man_db() {
  [ "$INSTALL_MANPAGES" -eq 1 ] || return 0

  local man_root=""
  man_root="$(dirname "$MAN_DIR")"

  case "$OS" in
    openbsd|netbsd)
      if has_cmd makewhatis; then
        if [ "$USE_ROOT_CMD" -eq 1 ]; then
          run_fs makewhatis "$man_root" >/dev/null 2>&1 || true
        else
          makewhatis "$man_root" >/dev/null 2>&1 || true
        fi
      fi
      ;;
    freebsd)
      if has_cmd makewhatis; then
        if [ "$USE_ROOT_CMD" -eq 1 ]; then
          run_fs makewhatis "$man_root" >/dev/null 2>&1 || true
        else
          makewhatis "$man_root" >/dev/null 2>&1 || true
        fi
      elif has_cmd mandb; then
        if [ "$USE_ROOT_CMD" -eq 1 ]; then
          run_fs mandb -q >/dev/null 2>&1 || true
        else
          mandb -q >/dev/null 2>&1 || true
        fi
      fi
      ;;
    darwin)
      if has_cmd mandb; then
        if [ "$USE_ROOT_CMD" -eq 1 ]; then
          run_fs mandb -q >/dev/null 2>&1 || true
        else
          mandb -q >/dev/null 2>&1 || true
        fi
      fi
      ;;
    linux|*)
      if has_cmd mandb; then
        if [ "$USE_ROOT_CMD" -eq 1 ]; then
          run_fs mandb -q >/dev/null 2>&1 || true
        else
          mandb -q >/dev/null 2>&1 || true
        fi
      elif has_cmd makewhatis; then
        if [ "$USE_ROOT_CMD" -eq 1 ]; then
          run_fs makewhatis "$man_root" >/dev/null 2>&1 || true
        else
          makewhatis "$man_root" >/dev/null 2>&1 || true
        fi
      fi
      ;;
  esac
}

verify_install() {
  local primary_path="${BIN_DIR}/${PRIMARY_NAME}"
  local secondary_path="${BIN_DIR}/${SECONDARY_NAME}"
  local primary_cmd=""
  local secondary_cmd=""
  local version_out=""

  step "verifying install"

  [ -x "$primary_path" ] || die "primary binary was not installed correctly"
  [ -L "$secondary_path" ] || die "secondary alias was not installed correctly"

  version_out="$("$primary_path" --version 2>/dev/null || true)"
  if [ -n "$version_out" ]; then
    okay "$version_out"
  else
    okay "binary is installed"
  fi

  if has_cmd "$PRIMARY_NAME"; then
    primary_cmd="$(command -v "$PRIMARY_NAME")"
    if [ "$primary_cmd" != "$primary_path" ]; then
      warn "'${PRIMARY_NAME}' resolves to ${primary_cmd} instead of ${primary_path}"
    fi
  else
    warn "'${PRIMARY_NAME}' is not in PATH yet"
  fi

  if has_cmd "$SECONDARY_NAME"; then
    secondary_cmd="$(command -v "$SECONDARY_NAME")"
    if [ "$secondary_cmd" != "$secondary_path" ]; then
      warn "'${SECONDARY_NAME}' resolves to ${secondary_cmd} instead of ${secondary_path}"
    fi
  else
    warn "'${SECONDARY_NAME}' is not in PATH yet"
  fi

  if ! path_in_env "$BIN_DIR"; then
    warn "${BIN_DIR} is not in PATH"
    note "add this to your shell profile:"
    printf '%s\n' "  export PATH=\"${BIN_DIR}:\$PATH\""
  fi

  if [ "$INSTALL_MANPAGES" -eq 1 ] && has_cmd man; then
    if man -w "$SECONDARY_NAME" >/dev/null 2>&1 && man -w "$PRIMARY_NAME" >/dev/null 2>&1; then
      okay "manual pages are available for both names"
    else
      warn "manpages were installed but your manpath may not include $(dirname "$MAN_DIR")"
      note "if needed, add this to your shell profile:"
      printf '%s\n' "  export MANPATH=\"$(dirname "$MAN_DIR"):\${MANPATH:-}\""
    fi
  fi
}

show_summary() {
  local primary_path="${BIN_DIR}/${PRIMARY_NAME}"
  local secondary_path="${BIN_DIR}/${SECONDARY_NAME}"

  [ "$QUIET" -eq 1 ] && return 0

  printf "\n"
  line
  printf "%b\n" "${C_BOLD}${C_GREEN}done${C_RESET}"
  printf "%b\n" "${C_DIM}${PRIMARY_NAME}:${C_RESET} ${primary_path}"
  printf "%b\n" "${C_DIM}${SECONDARY_NAME}:${C_RESET} ${secondary_path}"
  if [ "$INSTALL_MANPAGES" -eq 1 ]; then
    printf "%b\n" "${C_DIM}man:${C_RESET}      ${MAN_DIR}/${PRIMARY_MANPAGE}"
    printf "%b\n" "${C_DIM}man:${C_RESET}      ${MAN_DIR}/${SECONDARY_MANPAGE}"
  fi
  printf "\n"
  printf "%s\n" "Try:"
  printf "%s\n" "  ${SECONDARY_NAME} --help"
  printf "%s\n" "  ${PRIMARY_NAME} --help"
  if [ "$INSTALL_MANPAGES" -eq 1 ]; then
    printf "%s\n" "  man ${SECONDARY_NAME}"
    printf "%s\n" "  man ${PRIMARY_NAME}"
  fi
  line
}

main() {
  parse_args "$@"
  detect_platform
  detect_downloader
  detect_root_cmd
  finalize_paths
  decide_install_mode
  prepare_workspace
  render_header
  resolve_release

  if [ "$USE_ROOT_CMD" -eq 1 ]; then
    note "elevation will be used only for filesystem changes in protected locations"
  fi

  if [ "$FORCE_LOCAL" -eq 1 ]; then
    note "using local install prefix ${PREFIX}"
  fi

  if [ -n "$RELEASE_JSON" ]; then
    note "installing ${VERSION} (see $(releases_page_url))"
  elif [ "$USE_LATEST_REDIRECT" -eq 1 ]; then
    note "installing latest release via redirect (see $(releases_page_url))"
  else
    note "installing ${VERSION} using constructed asset URLs (see $(releases_page_url))"
  fi

  download_binary
  download_manpage
  install_binary
  install_manpages
  refresh_man_db
  verify_install
  show_summary
}

if [ "${BASH_SOURCE[0]-$0}" = "$0" ]; then
  main "$@"
fi
