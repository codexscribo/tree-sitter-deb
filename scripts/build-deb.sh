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
# Image used only to run ldd/dpkg-deb so dependency detection and package
# building are reproducible regardless of host OS (this script is expected
# to work from macOS too). Must be debian:13, not debian:12: on debian:13's
# merged-usr layout dpkg's file database indexes the canonical /usr/lib/...
# path that `readlink -f` resolves ldd's /lib/... symlink paths to; on
# debian:12 dpkg still indexes the pre-merge /lib/... path itself, so
# resolving the symlink first makes `dpkg -S` fail to find the owning
# package.
BUILD_IMAGE="${BUILD_IMAGE:-debian:13}"

# Debian packages to install inside the build container before running the
# ldd-based dependency-detection loop below, keyed by nothing in particular
# -- just a flat curated allowlist. Empirically verified empty against the
# current upstream release (libc6/libgcc-s1 are already present in the bare
# debian:12 image on both amd64 and arm64); if a future tree-sitter release
# picks up a new shared-library dependency not covered by the base image,
# add the owning package here. The hard-fail check in the detection loop
# guarantees this list can't silently fall out of date.
EXTRA_PACKAGES=()

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
  PKG_ROOT_CONTAINER="/work/$(basename "${PKG_ROOT}")"

  cat > "${WORK_DIR}/container-build.sh" <<'EOS'
set -euo pipefail

if [[ -n "$EXTRA_PACKAGES" ]]; then
  echo "Installing curated dependency packages: $EXTRA_PACKAGES"
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq --no-install-recommends $EXTRA_PACKAGES
fi

echo "Detecting runtime dependencies"
mapfile -t elf_files < <(find "$PKGROOT/usr/bin" -type f -perm -u+x 2>/dev/null)

declare -A dep_packages=()
missing_libs=()
for elf in "${elf_files[@]}"; do
  # Skip non-ELF files (e.g. shell scripts) silently.
  if ! ldd "$elf" >/dev/null 2>&1; then
    continue
  fi
  ldd_output="$(ldd "$elf" 2>/dev/null)"

  if grep -q 'not found$' <<<"$ldd_output"; then
    while IFS= read -r missing_line; do
      missing_libs+=("$elf: ${missing_line# }")
    done < <(grep 'not found$' <<<"$ldd_output")
  fi

  while IFS= read -r libpath; do
    [[ -z "$libpath" ]] && continue
    [[ "$libpath" == *"linux-vdso"* || "$libpath" == *"ld-linux"* ]] && continue
    [[ -e "$libpath" ]] || continue
    # dpkg's file list records canonical paths (e.g. /usr/lib/...), but ldd
    # reports paths through symlinks like /lib -> usr/lib, so resolve first.
    real_libpath="$(readlink -f "$libpath")"
    pkg="$(dpkg -S "$real_libpath" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    [[ -n "$pkg" ]] && dep_packages["$pkg"]=1
  done < <(awk '{ if ($3 ~ /^\//) print $3; else if ($1 ~ /^\//) print $1 }' <<<"$ldd_output")
done

if [[ ${#missing_libs[@]} -gt 0 ]]; then
  echo "ERROR: ldd reported unresolved shared library dependencies:" >&2
  printf '  %s\n' "${missing_libs[@]}" >&2
  echo "Add the Debian package that owns the missing SONAME(s) to the" >&2
  echo "EXTRA_PACKAGES allowlist in scripts/build-deb.sh." >&2
  exit 1
fi

ldd_depends="$(IFS=,; echo "${!dep_packages[*]}" | sed 's/,/, /g')"
[[ -n "$ldd_depends" ]] || { echo "ERROR: no dependencies detected via ldd" >&2; exit 1; }

sed -i "s|__DEPENDS__|${ldd_depends}|" "$PKGROOT/DEBIAN/control"

echo "Building ${OUT_DEB}"
dpkg-deb --root-owner-group --build "$PKGROOT" "$OUT_DEB"
EOS

  echo "Detecting dependencies and building package inside ${BUILD_IMAGE}"
  docker run --rm --platform "linux/${ARCH}" \
    -e "PKGROOT=${PKG_ROOT_CONTAINER}" \
    -e "EXTRA_PACKAGES=${EXTRA_PACKAGES[*]:-}" \
    -e "OUT_DEB=/work/${DEB_NAME}" \
    -v "${WORK_DIR}:/work" \
    "${BUILD_IMAGE}" bash /work/container-build.sh

  mkdir -p "${OUT_DIR}"
  cp "${WORK_DIR}/${DEB_NAME}" "${OUT_DIR}/${DEB_NAME}"
  echo "    built ${OUT_DIR}/${DEB_NAME}"

  rm -rf "${WORK_DIR}"
  trap - EXIT
done

echo "==> Done. Packages in ${OUT_DIR}"
