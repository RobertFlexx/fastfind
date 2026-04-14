#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install.sh
source "${SCRIPT_DIR}/install.sh"

PREFIX="/usr/local"
BIN_DIR="/usr/local/bin"
MAN_DIR="${PREFIX}/share/man/man1"
INSTALL_MANPAGES=0
REQUESTED_TAG=""

update_main() {
    detect_platform
    detect_downloader
    detect_root_cmd
    finalize_paths
    decide_install_mode

    local primary="${BIN_DIR}/${PRIMARY_NAME}"
    local expected_url="" expected_sha="" got="" inst_v="" want_v=""

    resolve_release

    while IFS= read -r url; do
        [ -n "$url" ] || continue
        expected_url="$url"
        break
    done <<< "$(list_binary_download_urls_ordered)"

    [ -n "$expected_url" ] || die "could not determine a download URL for ${PLATFORM_LABEL}. See $(releases_page_url)"

    expected_sha="$(lookup_asset_sha256 "$expected_url")"

    if [ -f "$primary" ] && [ -x "$primary" ]; then
        if [ -n "$expected_sha" ]; then
            got="$(file_sha256_hex "$primary")"
            if [ -n "$got" ] && [ "$got" = "$expected_sha" ]; then
                printf "%s\n" "already updated"
                exit 0
            fi
        else
            inst_v="$(installed_binary_version_token "$primary" || true)"
            want_v="$(normalize_release_version "$VERSION")"
            if [ -n "$inst_v" ] && [ -n "$want_v" ] && [ "$want_v" != "latest" ] && [ "$inst_v" = "$want_v" ]; then
                printf "%s\n" "already updated"
                exit 0
            fi
        fi
    fi

    prepare_workspace
    download_binary
    install_binary
    printf "updated to %s\n" "${VERSION}"
}

update_main "$@"
