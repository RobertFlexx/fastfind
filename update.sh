#!/usr/bin/env bash
set -Eeuo pipefail
# THIS SCRIPT USES PYTHON3! it is recommended to isntall python3.
REPO="${REPO:-RobertFlexx/fastfind}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"

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

if ! declare -F normalize_release_version >/dev/null 2>&1; then
normalize_release_version() {
  printf "%s" "$1" | sed 's/^[vV]//'
}
fi

if ! declare -F installed_binary_version_token >/dev/null 2>&1; then
installed_binary_version_token() {
  local bin="$1"
  local line=""
  [ -x "$bin" ] || return 1
  line="$($bin --version 2>/dev/null | head -n 1 || true)"
  printf "%s" "$line" | sed -n 's/.*\([0-9][0-9.]*\).*/\1/p' | head -n 1
}
fi

if ! declare -F file_sha256_hex >/dev/null 2>&1; then
file_sha256_hex() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    return 1
  fi
}
fi

if ! declare -F lookup_asset_sha256 >/dev/null 2>&1; then
lookup_asset_sha256() {
  local url="$1"

  [ -n "${RELEASE_JSON:-}" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
# since this embeds python because bash is a genuinely shit language, install python3 :)
  RELEASE_JSON_PAYLOAD="$RELEASE_JSON" python3 - "$url" <<'PY'
import json
import os
import sys

want = sys.argv[1]
payload = os.environ.get("RELEASE_JSON_PAYLOAD", "")
if not payload:
    raise SystemExit(0)

try:
    release = json.loads(payload)
except Exception:
    raise SystemExit(0)

found = False

for asset in release.get("assets") or []:
    if asset.get("browser_download_url") != want:
        continue

    found = True
    digest = asset.get("digest") or ""

    if isinstance(digest, str) and digest.startswith("sha256:"):
        print(digest.split(":", 1)[1])
        raise SystemExit(0)

# asset exists but no sha
if found:
    raise SystemExit(1)

# asset not found
raise SystemExit(0)
PY
}
fi

PREFIX="${OVERRIDE_PREFIX}"
BIN_DIR="${OVERRIDE_BIN_DIR}"
MAN_DIR="${OVERRIDE_MAN_DIR}"
REQUESTED_TAG="${OVERRIDE_REQUESTED_TAG}"
INSTALL_MANPAGES=1

PREFIX_EXPLICIT=1
BIN_DIR_EXPLICIT=1
MAN_DIR_EXPLICIT=1

update_main() {
  detect_platform
  detect_downloader
  detect_root_cmd
  finalize_paths
  decide_install_mode
  prepare_workspace
  render_header
  resolve_release

  local primary="${BIN_DIR}/${PRIMARY_NAME}"
  local secondary="${BIN_DIR}/${SECONDARY_NAME}"
  local expected_url=""
  local expected_sha=""
  local got_sha=""
  local installed_version=""
  local wanted_version=""
  local url=""

  while IFS= read -r url; do
    [ -n "$url" ] || continue
    expected_url="$url"
    break
  done <<< "$(list_binary_download_urls_ordered)"

  [ -n "$expected_url" ] || die "could not determine a download URL for ${PLATFORM_LABEL}. See $(releases_page_url)"

  expected_sha="$(lookup_asset_sha256 "$expected_url" || true)"

  if [ -x "$primary" ]; then
    if [ -n "$expected_sha" ]; then
      got_sha="$(file_sha256_hex "$primary" || true)"
      if [ -n "$got_sha" ] && [ "$got_sha" = "$expected_sha" ]; then
        note "${PRIMARY_NAME} is already current"
        if [ "$INSTALL_MANPAGES" -eq 1 ]; then
          download_manpage
          install_manpages
          refresh_man_db
        fi
        exit 0
      fi
    else
      installed_version="$(installed_binary_version_token "$primary" || true)"
      wanted_version="$(normalize_release_version "$VERSION")"
      if [ -n "$installed_version" ] && [ -n "$wanted_version" ] && [ "$wanted_version" != "latest" ] && [ "$installed_version" = "$wanted_version" ]; then
        note "${PRIMARY_NAME} is already current"
        if [ "$INSTALL_MANPAGES" -eq 1 ]; then
          download_manpage
          install_manpages
          refresh_man_db
        fi
        exit 0
      fi
    fi
  fi

  if [ "$USE_ROOT_CMD" -eq 1 ]; then
    note "elevation will be used only for filesystem changes in protected locations"
  fi

  note "updating ${PRIMARY_NAME}"
  download_binary
  download_manpage
  install_binary
  install_manpages
  refresh_man_db
  verify_install

  if [ -x "$secondary" ] && [ ! -L "$secondary" ]; then
    warn "${secondary} exists but is not a symlink"
  fi

  printf 'updated to %s\n' "${VERSION}"
}

if [ "${BASH_SOURCE[0]-$0}" = "$0" ]; then
  update_main "$@"
fi
