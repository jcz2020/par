<!-- language: en -->

# PAR v0.3.5

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
PAR_INSTALL_VERSION=v0.3.5 \
  curl -fsSL https://raw.githubusercontent.com/jcz2020/par/main/install.sh | bash
```

### Upgrade an existing install

```bash
par upgrade
```

This fetches the latest release, verifies the checksum, and atomically
replaces the running binary.

### opam

```bash
opam install par par_cli
```

Both packages resolve against the public opam repository; no extra
configuration is required. The `par_postgres` opam package is published
separately and is only needed if you want the PostgreSQL persistence
backend.

### PyPI (Python binding)

```bash
pip install par_runtime
```

The Python binding ships as a ctypes wrapper around the C ABI
(`par_capi.so`). The wheel bundles the ABI, so no OCaml toolchain is
required at install time.

### Build from source

For platforms without a published binary, or for development:

```bash
git clone https://github.com/jcz2020/par.git
cd par
bash scripts/build-from-source.sh
```

The script installs the system C libraries (`libgmp`, `libsqlite3`,
`libpq`, `libssl`), bootstraps opam and OCaml 5.4 if needed, builds the
runtime, and installs the `par` binary to `/usr/local/bin/par`.

## Verify

```bash
par --version
```

Should print `par 0.3.5` (or later for `par upgrade` users).

## Assets

This release ships three binaries plus a checksum file:

| Asset | Platform |
|-------|----------|
| `par-v0.3.5-linux-x64` | Linux x86_64 (Ubuntu, Debian, Fedora, Arch, Alpine) |
| `par-v0.3.5-macos-arm64` | macOS 15+ on Apple Silicon |
| `par-v0.3.5-macos-x64` | macOS 13+ on Intel |
| `sha512-checksums.txt` | SHA-512 digests for all three binaries |

To verify a downloaded binary manually:

```bash
sha512sum -c <(grep par-v0.3.5-linux-x64 sha512-checksums.txt)
```

## Links

- Source: <https://github.com/jcz2020/par>
- Documentation: <https://github.com/jcz2020/par/blob/main/docs/index.md>
- Issues: <https://github.com/jcz2020/par/issues>
- CHANGES: <https://github.com/jcz2020/par/blob/main/CHANGES.md>
