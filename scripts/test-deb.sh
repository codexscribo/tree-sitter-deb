#!/usr/bin/env bash
# Install, smoke-test, and uninstall a built tree-sitter-cli .deb inside a
# distro container.
#
# Usage: test-deb.sh <tree-sitter-cli-deb> <expected-version>
# Intended to run as root inside an Ubuntu/Debian Docker container.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <tree-sitter-cli-deb> <expected-version>" >&2
  exit 1
fi

deb_path="$1"
expected_version="$2"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -f "$deb_path" ]] || fail "deb file not found: $deb_path"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq || fail "apt-get update"

echo "==> Installing ${deb_path}"
apt-get install -y -qq "./${deb_path}" || fail "apt-get install"

echo "==> Verifying installation"
command -v tree-sitter >/dev/null || fail "tree-sitter not found on PATH after install"

version_output="$(tree-sitter --version)"
echo "$version_output" | grep -qF "$expected_version" || fail "tree-sitter --version does not report '$expected_version'"

tree-sitter --help >/dev/null || fail "tree-sitter --help failed"

dpkg -s tree-sitter-cli | grep -q "^Status: install ok installed" || fail "dpkg status for tree-sitter-cli is not 'install ok installed'"

echo "==> Uninstalling tree-sitter-cli"
apt-get remove -y -qq tree-sitter-cli || fail "apt-get remove"
hash -r

if command -v tree-sitter >/dev/null 2>&1; then
  fail "tree-sitter still present after removal"
fi

echo "PASS: all checks succeeded"
