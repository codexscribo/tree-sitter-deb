#!/usr/bin/env bash
# Build .deb packages that repackage the official tree-sitter CLI binary
# release (https://github.com/tree-sitter/tree-sitter/releases) for
# Debian/Ubuntu, amd64 and arm64.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

UPSTREAM_REPO="tree-sitter/tree-sitter"
DEB_REVISION="${DEB_REVISION:-1}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist}"
TS_VERSION="latest"
ARCHES="amd64 arm64"
# Image used only to run dpkg-deb/fakeroot so builds are reproducible
# regardless of host OS (this script is expected to work from macOS too).
BUILD_IMAGE="${BUILD_IMAGE:-debian:12}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--version <tree-sitter tag, e.g. v0.26.10|latest>] [--arch <amd64|arm64|all>] [--out-dir <dir>]

Env overrides: DEB_REVISION, OUT_DIR, BUILD_IMAGE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) TS_VERSION="$2"; shift 2 ;;
    --arch) ARCHES="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "${ARCHES}" == "all" ]]; then
  ARCHES="amd64 arm64"
fi

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

case "$(uname -m)" in
  x86_64|amd64) BUILD_PLATFORM="amd64" ;;
  arm64|aarch64) BUILD_PLATFORM="arm64" ;;
  *) BUILD_PLATFORM="amd64" ;;
esac

if [[ "${TS_VERSION}" == "latest" ]]; then
  LATEST_JSON="$(curl -fsSL "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest")"
  TS_VERSION="$(echo "${LATEST_JSON}" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
fi
[[ -n "${TS_VERSION}" ]] || { echo "Could not resolve tree-sitter version" >&2; exit 1; }

UPSTREAM_VERSION="${TS_VERSION#v}"
PKG_VERSION="${UPSTREAM_VERSION}-${DEB_REVISION}"

echo "==> Packaging tree-sitter-cli ${PKG_VERSION} (upstream ${TS_VERSION}) for: ${ARCHES}"

mkdir -p "${OUT_DIR}"

deb_arch_asset() {
  case "$1" in
    amd64) echo "tree-sitter-linux-x64.gz" ;;
    arm64) echo "tree-sitter-linux-arm64.gz" ;;
    *) echo "Unsupported arch: $1" >&2; exit 1 ;;
  esac
}

for ARCH in ${ARCHES}; do
  echo "--> Building ${ARCH}"
  ASSET="$(deb_arch_asset "${ARCH}")"
  ASSET_URL="https://github.com/${UPSTREAM_REPO}/releases/download/${TS_VERSION}/${ASSET}"

  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "${WORK_DIR}"' EXIT

  PKG_ROOT="${WORK_DIR}/tree-sitter-cli_${PKG_VERSION}_${ARCH}"
  mkdir -p "${PKG_ROOT}/DEBIAN" "${PKG_ROOT}/usr/bin" "${PKG_ROOT}/usr/share/doc/tree-sitter-cli"

  echo "    downloading ${ASSET_URL}"
  curl -fsSL "${ASSET_URL}" -o "${WORK_DIR}/${ASSET}"
  gunzip -c "${WORK_DIR}/${ASSET}" > "${PKG_ROOT}/usr/bin/tree-sitter"
  chmod 755 "${PKG_ROOT}/usr/bin/tree-sitter"

  cp "${ROOT_DIR}/debian/copyright" "${PKG_ROOT}/usr/share/doc/tree-sitter-cli/copyright"

  CHANGELOG="${WORK_DIR}/changelog.Debian"
  sed -e "s/__VERSION__/${PKG_VERSION}/g" \
      -e "s/__UPSTREAM_TAG__/${TS_VERSION}/g" \
      -e "s/__ARCH__/${ARCH}/g" \
      -e "s/__DATE__/$(date -R)/g" \
      "${ROOT_DIR}/debian/changelog.template" > "${CHANGELOG}"
  gzip -9 -n -c "${CHANGELOG}" > "${PKG_ROOT}/usr/share/doc/tree-sitter-cli/changelog.Debian.gz"

  INSTALLED_SIZE="$(du -sk "${PKG_ROOT}/usr" | cut -f1)"
  sed -e "s/__VERSION__/${PKG_VERSION}/g" \
      -e "s/__ARCH__/${ARCH}/g" \
      -e "s/__INSTALLED_SIZE__/${INSTALLED_SIZE}/g" \
      "${ROOT_DIR}/debian/control.template" > "${PKG_ROOT}/DEBIAN/control"

  DEB_NAME="tree-sitter-cli_${PKG_VERSION}_${ARCH}.deb"
  # dpkg-deb just archives files; it doesn't need to run under the target
  # package's CPU arch, so pin the container to the host's native platform
  # to avoid pointless emulation.
  docker run --rm --platform "linux/${BUILD_PLATFORM}" -v "${WORK_DIR}:/work" "${BUILD_IMAGE}" \
    dpkg-deb --root-owner-group --build "/work/$(basename "${PKG_ROOT}")" "/work/${DEB_NAME}"

  mkdir -p "${OUT_DIR}"
  cp "${WORK_DIR}/${DEB_NAME}" "${OUT_DIR}/${DEB_NAME}"
  echo "    built ${OUT_DIR}/${DEB_NAME}"

  rm -rf "${WORK_DIR}"
  trap - EXIT
done

echo "==> Done. Packages in ${OUT_DIR}"
