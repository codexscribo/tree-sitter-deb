#!/usr/bin/env bash
# Install / smoke-test / uninstall the built tree-sitter-cli .deb packages
# across the supported Debian and Ubuntu releases, using Docker.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEB_DIR="${DEB_DIR:-${ROOT_DIR}/dist}"
ARCHES="amd64 arm64"
DISTROS="ubuntu:22.04 ubuntu:24.04 ubuntu:26.04 debian:11 debian:12 debian:13"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--arch <amd64|arm64|all>] [--distro <image|all>] [--deb-dir <dir>]

Examples:
  $(basename "$0")                                  # full matrix
  $(basename "$0") --arch amd64 --distro debian:12   # single combo
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCHES="$2"; shift 2 ;;
    --distro) DISTROS="$2"; shift 2 ;;
    --deb-dir) DEB_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ "${ARCHES}" == "all" ]] && ARCHES="amd64 arm64"
[[ "${DISTROS}" == "all" ]] && DISTROS="ubuntu:22.04 ubuntu:24.04 ubuntu:26.04 debian:11 debian:12 debian:13"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

read -r -d '' INNER_SCRIPT <<'EOS' || true
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
DEB_FILE="$1"

apt-get update -qq
apt-get install -y -qq "${DEB_FILE}"

echo "---- installed metadata ----"
dpkg-query -W -f='${Package} ${Version} ${Architecture} ${Status}\n' tree-sitter-cli

echo "---- tree-sitter --version ----"
tree-sitter --version

echo "---- tree-sitter --help ----"
tree-sitter --help >/dev/null

command -v tree-sitter >/dev/null || { echo "tree-sitter not on PATH after install" >&2; exit 1; }

echo "---- removing package ----"
apt-get remove -y -qq tree-sitter-cli
hash -r

if command -v tree-sitter >/dev/null 2>&1; then
  echo "FAIL: tree-sitter binary still present after removal" >&2
  exit 1
fi

echo "OK"
EOS

RESULTS=()
FAILED=0

for DISTRO in ${DISTROS}; do
  for ARCH in ${ARCHES}; do
    DEB_FILE_HOST="$(ls "${DEB_DIR}"/tree-sitter-cli_*_"${ARCH}".deb 2>/dev/null | head -1 || true)"
    LABEL="${DISTRO} / ${ARCH}"

    if [[ -z "${DEB_FILE_HOST}" ]]; then
      echo "SKIP  ${LABEL}: no .deb found in ${DEB_DIR} for ${ARCH} (run scripts/build-deb.sh first)"
      RESULTS+=("SKIP  ${LABEL}")
      continue
    fi

    DEB_BASENAME="$(basename "${DEB_FILE_HOST}")"
    echo ""
    echo "==================== ${LABEL} ===================="

    if docker run --rm \
        --platform "linux/${ARCH}" \
        -v "${DEB_DIR}:/debs:ro" \
        "${DISTRO}" \
        bash -c "${INNER_SCRIPT}" _ "/debs/${DEB_BASENAME}"; then
      RESULTS+=("PASS  ${LABEL}")
    else
      RESULTS+=("FAIL  ${LABEL}")
      FAILED=1
    fi
  done
done

echo ""
echo "==================== summary ===================="
for R in "${RESULTS[@]}"; do
  echo "${R}"
done

exit "${FAILED}"
