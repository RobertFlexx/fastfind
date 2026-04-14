#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-RobertFlexx/fastfind}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"

# Preserve caller overrides before sourcing install.sh, because install.sh sets its own defaults.
OVERRIDE_PREFIX="${PREFIX:-/usr/local}"
OVERRIDE_BIN_DIR="${BIN_DIR:-${OVERRIDE_PREFIX}/bin}"
OVERRIDE_MAN_DIR="${MAN_DIR:-${OVERRIDE_PREFIX}/share/man/man1}"
OVERRIDE_REQUESTED_TAG="${REQUESTED_TAG:-}"

INSTALL_LIB=""
TMP_INSTALL_LIB=""

cleanup_update() {
    if [ -n "${TMP_INSTALL_LIB:-}" ] && [ -f "${TMP_INSTALL_LIB}" ]; then
        rm -f "${TMP_INSTALL_LIB}"
    fi
}

trap cleanup_update EXIT INT TERM

download_update_dep() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 1 --retry-all-errors -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        printf '%s\n' "error: curl or wget is required" >&2
        exit 1
    fi
}

resolve_install_lib() {
    local self_path=""
    local script_dir=""

    self_path="${BASH_SOURCE[0]-}"

    if [ -n "$self_path" ] && [ -f "$self_path" ]; then
        script_dir="$(cd -- "$(dirname -- "$self_path")" && pwd -P)"
        if [ -f "${script_dir}/install.sh" ]; then
            INSTALL_LIB="${script_dir}/install.sh"
            return 0
        fi
    fi

    TMP_INSTALL_LIB="$(mktemp "${TMPDIR:-/tmp}/fastfind-install.XXXXXX.sh")"
    download_update_dep "${RAW_BASE}/install.sh" "${TMP_INSTALL_LIB}"
    INSTALL_LIB="${TMP_INSTALL_LIB}"
}

resolve_install_lib

# shellcheck source=/dev/null
source "${INSTALL_LIB}"

# Re-apply update-specific settings after sourcing install.sh.
PREFIX="${OVERRIDE_PREFIX}"
BIN_DIR="${OVERRIDE_BIN_DIR}"
MAN_DIR="${OVERRIDE_MAN_DIR}"
REQUESTED_TAG="${OVERRIDE_REQUESTED_TAG}"
INSTALL_MANPAGES=0

PREFIX_EXPLICIT=1
BIN_DIR_EXPLICIT=1
MAN_DIR_EXPLICIT=1

update_main() {
    detect_platform
    detect_downloader
    detect_root_cmd
    finalize_paths
    decide_install_mode

    local primary="${BIN_DIR}/${PRIMARY_NAME}"
    local expected_url=""
    local expected_sha=""
    local got=""
    local inst_v=""
    local want_v=""
    local url=""

    resolve_release

    while IFS= read -r url; do
        [ -n "$url" ] || continue
        expected_url="$url"
        break
    done <<< "$(list_binary_download_urls_ordered)"

    [ -n "$expected_url" ] || die "could not determine a download URL for ${PLATFORM_LABEL}. See $(releases_page_url)"

    expected_sha="$(lookup_asset_sha256 "$expected_url")"

    if [ -x "$primary" ]; then
        if [ -n "$expected_sha" ]; then
            got="$(file_sha256_hex "$primary")"
            if [ -n "$got" ] && [ "$got" = "$expected_sha" ]; then
                printf '%s\n' "already updated"
                exit 0
            fi
        else
            inst_v="$(installed_binary_version_token "$primary" || true)"
            want_v="$(normalize_release_version "$VERSION")"
            if [ -n "$inst_v" ] && [ -n "$want_v" ] && [ "$want_v" != "latest" ] && [ "$inst_v" = "$want_v" ]; then
                printf '%s\n' "already updated"
                exit 0
            fi
        fi
    fi

    prepare_workspace
    download_binary
    install_binary
    printf 'updated to %s\n' "${VERSION}"
}

if [ "${BASH_SOURCE[0]-$0}" = "$0" ]; then
    update_main "$@"
fi
