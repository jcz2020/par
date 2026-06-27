<!-- language: en -->

# PAR __VERSION__

> **Before using a release binary on macOS:** the binary is unsigned, so macOS
> Gatekeeper will refuse to launch it. After installing, run
> `xattr -cr "$(command -v par)"` once to clear the quarantine flag. Without
> this, you'll see "par cannot be opened because the developer cannot be
> verified" the first time you run it.

## Install

### One-liner (Linux + macOS, recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
```

The script auto-detects your platform, downloads the matching binary from this
release, verifies its SHA-512 against `sha512-checksums.txt`, and installs it
to `/usr/local/bin/par` (override with `PAR_INSTALL_PREFIX=~/.local`).

To pin a specific version instead of the latest:

```bash
PAR_INSTALL_VERSION=__VERSION__ \
  curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
```

### Upgrade an existing install

```bash
par update
```

This fetches the latest release, verifies the checksum, and atomically
replaces the running binary.

### opam

```bash
opam install par par_cli
```

Both packages resolve against the public opam repository; no extra
configuration is required. The published packages are `par` and
`par_cli`. SQLite is the only persistence backend; no separate database
package is needed.

### PyPI (Python binding)

```bash
pip install par-runtime
```

The Python binding ships as a ctypes wrapper around the C ABI
(`par_capi.so`). v0.5.0+ ships native wheels for **linux x86_64**
(`manylinux_2_28`) and **macOS arm64** (Apple Silicon). On other platforms
(Intel Mac, ARM Linux, Windows), pip falls back to source build — see
[`CHANGES.md`](../CHANGES.md) for the current platform support matrix.

### Build from source

For platforms without a published binary, or for development:

```bash
git clone https://github.com/jcz2020/par.git
cd par
bash scripts/build-from-source.sh
```

The script installs the system C libraries (`libgmp`, `libsqlite3`,
`libssl`), bootstraps opam and OCaml 5.4 if needed, builds the
runtime, and installs the `par` binary to `/usr/local/bin/par`.

## Verify

```bash
par --version
```

## Assets

This release ships binaries, wheels, and a checksum file:

| Asset | Platform |
|-------|----------|
| `par-__VERSION__-linux-x64` | Linux x86_64 (Ubuntu, Debian, Fedora, Arch, Alpine) |
| `par-__VERSION__-macos-arm64` | macOS 15+ on Apple Silicon |
| `par_runtime-__VERSION__-py3-none-manylinux_2_28_x86_64.whl` | Python wheel — Linux x86_64 |
| `par_runtime-__VERSION__-py3-none-macosx_11_0_arm64.whl` | Python wheel — macOS arm64 |
| `sha512-checksums.txt` | SHA-512 digests for all binaries |

**Note**: Intel Mac binary (`macos-x64`) is not shipped since v0.5.0 — the
`macos-13` GH Actions runner was permanently abandoned (free-tier queue
24h+). ARM64 Linux wheel deferred to v0.5.1+. See [`CHANGES.md`](../CHANGES.md).

To verify a downloaded binary manually:

```bash
sha512sum -c <(grep par-__VERSION__-linux-x64 sha512-checksums.txt)
```

## Links

- Source: <https://github.com/jcz2020/par>
- Documentation: <https://github.com/jcz2020/par/blob/main/docs/index.md>
- Issues: <https://github.com/jcz2020/par/issues>
- CHANGES: <https://github.com/jcz2020/par/blob/main/CHANGES.md>
