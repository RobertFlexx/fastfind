#!/usr/bin/env bash
set -euo pipefail

REPO="RobertFlexx/fastfind"
INSTALL_DIR="/usr/local/bin"
MAN_DIR="/usr/share/man/man1"
BINARY_NAME="ff"

die() {
    printf "error: %s\n" "$1" >&2
    exit 1
}

info() {
    printf "%s\n" "$1"
}

warn() {
    printf "warning: %s\n" "$1" >&2
}

cleanup() {
    rm -f "${TMP_BIN:-}" "${TMP_MAN:-}"
}

detect_platform() {
    local os arch

    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"

    case "$os" in
        linux)   OS="linux" ;;
        darwin)  OS="darwin" ;;
        freebsd) OS="freebsd" ;;
        openbsd) OS="openbsd" ;;
        netbsd)  OS="netbsd" ;;
        *)       die "unsupported operating system: $os" ;;
    esac

    case "$arch" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l)        ARCH="arm" ;;
        i386|i686)     ARCH="386" ;;
        *)             die "unsupported architecture: $arch" ;;
    esac
}

detect_downloader() {
    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget"
    else
        die "curl or wget required"
    fi
}

download() {
    local url="$1" dest="$2"
    case "$DOWNLOADER" in
        curl) curl -fsSL -o "$dest" "$url" ;;
        wget) wget -qO "$dest" "$url" ;;
    esac
}

get_latest_version() {
    local url="https://api.github.com/repos/${REPO}/releases/latest"
    local json

    case "$DOWNLOADER" in
        curl) json="$(curl -fsSL "$url")" ;;
        wget) json="$(wget -qO- "$url")" ;;
    esac

    VERSION="$(printf "%s" "$json" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')"

    if [ -z "$VERSION" ]; then
        die "failed to determine latest version"
    fi
}

can_write() {
    [ -w "$1" ] || [ -w "$(dirname "$1")" ]
}

run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    else
        die "root privileges required for $INSTALL_DIR; install sudo or run as root"
    fi
}

check_existing() {
    local existing
    existing="$(command -v "$BINARY_NAME" 2>/dev/null || true)"

    if [ -n "$existing" ] && [ "$existing" != "${INSTALL_DIR}/${BINARY_NAME}" ]; then
        warn "existing $BINARY_NAME found at $existing"
        warn "installing to ${INSTALL_DIR}/${BINARY_NAME} (may shadow existing)"
    fi
}

install_binary() {
    local asset_name url

    asset_name="${BINARY_NAME}-${OS}-${ARCH}"
    url="https://github.com/${REPO}/releases/download/${VERSION}/${asset_name}"

    TMP_BIN="$(mktemp)"

    info "downloading ${BINARY_NAME} ${VERSION} for ${OS}/${ARCH}"
    download "$url" "$TMP_BIN" || die "download failed: ${url}"

    chmod +x "$TMP_BIN"

    info "installing to ${INSTALL_DIR}/${BINARY_NAME}"
    if can_write "$INSTALL_DIR"; then
        install -m 755 "$TMP_BIN" "${INSTALL_DIR}/${BINARY_NAME}"
    else
        run_privileged install -m 755 "$TMP_BIN" "${INSTALL_DIR}/${BINARY_NAME}"
    fi
}

install_manpage() {
    local url

    url="https://raw.githubusercontent.com/${REPO}/main/mandoc/${BINARY_NAME}.1"

    if [ ! -d "$MAN_DIR" ]; then
        info "man directory not found; skipping manpage"
        return 0
    fi

    TMP_MAN="$(mktemp)"

    if ! download "$url" "$TMP_MAN" 2>/dev/null; then
        info "manpage not available; skipping"
        return 0
    fi

    if [ ! -s "$TMP_MAN" ]; then
        info "manpage empty; skipping"
        return 0
    fi

    info "installing manpage to ${MAN_DIR}/${BINARY_NAME}.1"
    if can_write "$MAN_DIR"; then
        install -m 644 "$TMP_MAN" "${MAN_DIR}/${BINARY_NAME}.1"
    else
        run_privileged install -m 644 "$TMP_MAN" "${MAN_DIR}/${BINARY_NAME}.1"
    fi

    if command -v mandb >/dev/null 2>&1; then
        run_privileged mandb -q 2>/dev/null || true
    elif command -v makewhatis >/dev/null 2>&1; then
        run_privileged makewhatis "$MAN_DIR" 2>/dev/null || true
    fi
}

verify_install() {
    local installed_path

    if command -v "$BINARY_NAME" >/dev/null 2>&1; then
        installed_path="$(command -v "$BINARY_NAME")"
        info "installed: $("$BINARY_NAME" --version 2>/dev/null || echo "$BINARY_NAME") at $installed_path"
    elif [ -x "${INSTALL_DIR}/${BINARY_NAME}" ]; then
        info "installed to ${INSTALL_DIR}/${BINARY_NAME}"
        warn "${INSTALL_DIR} is not in PATH"
    else
        die "installation failed"
    fi

    if ! command -v man >/dev/null 2>&1; then
        info "man not found; manpage installed but man command unavailable"
    fi
}

main() {
    trap cleanup EXIT

    info "fastfind installer"
    info ""

    detect_platform
    detect_downloader
    get_latest_version
    check_existing

    install_binary
    install_manpage
    verify_install

    info ""
    info "run 'ff --help' to get started"
}

main "$@"
