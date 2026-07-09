# tree-sitter-deb

Repackages the official [tree-sitter](https://github.com/tree-sitter/tree-sitter)
CLI binary releases as `.deb` packages for Debian and Ubuntu.

This repository does not build tree-sitter from source. It downloads the
prebuilt `tree-sitter-linux-{x64,arm64}.gz` binaries that the upstream
project publishes on its
[GitHub Releases](https://github.com/tree-sitter/tree-sitter/releases) page
and wraps each one in a `.deb` under the package name `tree-sitter-cli` —
the same name used by the official Debian/Ubuntu archive package — so
installing it replaces (or provides, on releases that don't yet carry it)
the distro package.

## Supported targets

| Distro | Version | Status |
| --- | --- | --- |
| Ubuntu | 22.04 | ⚠️ installs, binary doesn't run (see below) |
| Ubuntu | 24.04 | ✅ |
| Ubuntu | 26.04 | ✅ |
| Debian | 11 (bullseye) | ⚠️ installs, binary doesn't run (see below) |
| Debian | 12 (bookworm) | ⚠️ installs, binary doesn't run (see below) |
| Debian | 13 (trixie) | ✅ |

Architectures: `amd64`, `arm64`.

Every combination above is exercised by the test matrix, but a given
`.deb` is architecture-specific only — the same `tree-sitter-cli_<version>_amd64.deb`
is installed and smoke-tested across all six distro/version targets (and
likewise for `arm64`), since the upstream binary itself is not built
differently per distro.

### Known limitation: GLIBC 2.39

Upstream tree-sitter release binaries since `v0.25.0` are linked against
`GLIBC_2.39` ([tree-sitter/tree-sitter#4174](https://github.com/tree-sitter/tree-sitter/issues/4174),
still unresolved as of this writing). Debian 11 (glibc 2.31), Debian 12
(glibc 2.36), and Ubuntu 22.04 (glibc 2.35) don't have that available, so
the `.deb` installs cleanly on those releases but the `tree-sitter` binary
fails to start with an error like:

```
tree-sitter: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by tree-sitter)
```

This repository always repackages the latest official upstream binary
as-is rather than pinning an older, glibc-compatible release, so those
three targets are tracked in CI (`continue-on-error`) but are not
currently functional. If upstream lowers the baseline again, or you need
a working build on those releases today, the last upstream tag unaffected
by this regression is `v0.24.7` (`./scripts/build-deb.sh v0.24.7 amd64`).

## Installing

Download the `.deb` matching your architecture from the
[Releases](https://github.com/codexscribo/tree-sitter-deb/releases) page,
then:

```sh
sudo apt install ./tree-sitter-cli_<version>_<arch>.deb
```

`apt install ./<file>.deb` resolves dependencies and, if the distro already
ships `tree-sitter-cli`, replaces it in place. Verify with:

```sh
tree-sitter --version
```

Uninstall the same way you'd remove any package:

```sh
sudo apt remove tree-sitter-cli
```

## Repository layout

```
debian/                        control/copyright/changelog templates used to build the package
scripts/build-deb.sh           downloads the upstream binary and produces a .deb
scripts/test-deb.sh            installs/smoke-tests/uninstalls a single .deb inside a container
.github/workflows/release.yml  builds, tests, and publishes a GitHub release
```

## Building locally

Requires `docker`, `curl`, and `bash`. `ldd`/`dpkg-deb` themselves run
inside a `debian:13` container, so this works from macOS or any Linux host
without installing Debian tooling locally. One architecture per invocation:

```sh
# Build the latest upstream release, packaging revision 1
./scripts/build-deb.sh latest amd64
./scripts/build-deb.sh latest arm64

# Build a specific upstream version / revision
./scripts/build-deb.sh v0.26.10 amd64 2
```

Output goes to `dist/`.

## Testing locally

`test-deb.sh` installs/smoke-tests/uninstalls one `.deb` and expects to run
as root inside the target distro's container already — it doesn't invoke
Docker itself. Run it the same way `release.yml` does, once per
distro/arch combination you want to check:

```sh
docker run --rm --platform linux/amd64 \
  -v "$PWD:/w" -w /w debian:13 \
  ./scripts/test-deb.sh ./dist/tree-sitter-cli_0.26.10-1_amd64.deb 0.26.10
```

On non-Linux/amd64 hosts (e.g. Apple Silicon, or testing `arm64` from an
`amd64` host), Docker needs multi-arch emulation enabled (`docker run
--privileged --rm tonistiigi/binfmt --install all`, or
`docker/setup-qemu-action` in CI).

## Release process

`release.yml`:

1. Triggers on a manual dispatch (optionally pinning an upstream
   `ts_version` and/or `deb_revision`), or a daily schedule that checks
   whether upstream has a new release we haven't packaged yet.
2. Resolves the target upstream tag and the package revision to publish —
   auto-picking the next `deb_revision` for that version by scanning
   existing release tags, unless one is passed in explicitly.
3. Builds `.deb`s for both architectures.
4. Runs the full install/test/uninstall matrix.
5. Publishes (or updates) a GitHub release with the `.deb`s and a
   `SHA256SUMS` file, creating the `vX.Y.Z-N` tag if it doesn't exist yet.

The release tag/package version is `<upstream-version>-<deb-revision>`,
e.g. `v0.26.10-1` for upstream `v0.26.10`, packaging revision 1. The
scheduled run skips packaging a version that already has a published
release (of any revision); a manual dispatch always proceeds, which is how
you re-publish a packaging-only fix under a bumped `deb_revision` without
waiting for a new upstream release.

The package's `Depends:` field is not hardcoded — `build-deb.sh` resolves it
by running `ldd` against the packaged binary inside the build container and
mapping each shared library it needs back to the Debian package that owns
it. If a future upstream release picks up a new shared-library dependency
not already covered by the base build image, the build fails loudly instead
of silently shipping a package with a missing `Depends:` entry.

## License

Packaging scripts and metadata in this repository: MIT (see `LICENSE`).
The packaged `tree-sitter` binary itself is upstream's, under its own MIT
license (see `debian/copyright`).
