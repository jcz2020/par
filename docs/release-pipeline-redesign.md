# Release Pipeline Redesign — Post v0.4.10 Postmortem

> **✅ RESOLVED 2026-06-21**: v0.4.11 shipped the MVP fix (3-platform acceptance test, setuptools upgrade, ubuntu-22.04 pinning). v0.4.13 shipped manylinux_2_28 wheel (auditwheel + GMP/sqlite3 bundling). v0.5.0 shipped macOS arm64 wheel (delocate + `wheel tags`). ARM64 Linux deferred to v0.5.1+ (GH Actions free-tier ARM runners saturated). OIDC trusted publisher pending user registration at pypi.org. See [`CHANGES.md`](../CHANGES.md) for release notes; this doc is now a historical retrospective.

**Status (historical)**: Updated 2026-06-21 — scope split into v0.4.11 (MVP fix) and v0.5+ (stretch goals).
**Scope**:
- **v0.4.11** (PATCH, immediate): minimum viable fix + end-to-end acceptance test → see [`v0.4.11-ROADMAP.md`](v0.4.11-ROADMAP.md) for execution plan
- **v0.5.0+** (MINOR, stretch): manylinux + auditwheel + ARM64 + macOS wheel + OIDC auto-upload
**Decision needed**: answered in v0.4.11 ROADMAP for the immediate scope; v0.5+ open questions in §8 below.

---

## 1. What Went Wrong (3 P0s in 47 hours)

| # | Issue | Version | Symptom | Root cause |
|---|-------|---------|---------|------------|
| 1 | [PAR-0qf](https://github.com/jcz2020/par/issues) | v0.4.8 wheel | `OSError: par_capi.so: cannot open shared object file` on `import par_runtime` | `pypi-publish.yml` line 31 copies `.so` to `bindings/python/par_runtime/` (root), but `pyproject.toml` line 15 declares `package-data = ["lib/*.so"]` (subdir). Path mismatch never caught because no end-to-end install test ran before PyPI upload. |
| 2 | [PAR-8cs](https://github.com/jcz2020/par/issues) | v0.4.8 + v0.4.9 binaries + v0.4.9 wheel | `version GLIBC_2.38 not found` on Debian 12, Ubuntu 22.04 LTS, RHEL 9 | All workflows used `ubuntu-latest`, which rolled forward to Ubuntu 24.04 (glibc 2.39). Resulting ELF artifacts require `GLIBC_2.38`. Excludes most production Linux distros. |
| 3 | [PAR-cog](https://github.com/jcz2020/par/issues) | v0.4.10 wheel | Built as `UNKNOWN-0.0.0-py3-none-any.whl` (useless) | After switching to `ubuntu-22.04` for PAR-8cs, the default setuptools (~59) doesn't support PEP 621 `[project]` table (needs setuptools >= 61). Falls back to UNKNOWN defaults. |

**Common pattern**: Each bug is local and small. None would have survived a true end-to-end test. The pipeline gates on "build succeeded" not "user can install + use on target platform".

---

## 2. Systemic Root Causes

1. **No platform-matrix install test.** Build artifacts are tested only on the build host (CI runner), not on representative target platforms (Debian stable, Ubuntu LTS, RHEL).
2. **No acceptance gate before PyPI upload.** `twine upload` runs immediately after `pip wheel`, with no test in between. A broken wheel goes live globally within seconds.
3. **No pinned build environment.** `ubuntu-latest` is a moving target. We treat it as a constant, but GitHub bumps it ~yearly. Each bump silently raises glibc requirements.
4. **No local CI dry-run.** Every workflow change requires a `git push` to test. Iteration cycle is 5-10 minutes per attempt, encouraging "ship and see" instead of "verify before ship".
5. **`install.sh` test masked the binary bug.** Local `make install-dev` overwrites `/usr/local/bin/par` with a locally-compiled binary (glibc 2.35). I tested `par --version` after `make install-dev`, which silently hid the fact that the GH Release binary (glibc 2.38) was broken. **Manual QA without isolation is theater.**

---

## 3. Design Options

### Option A: manylinux + auditwheel (industry standard)

Build the wheel inside a manylinux container, then run `auditwheel` to repair and tag it.

- **Container**: `quay.io/pypa/manylinux_2_28_x86_64` (glibc 2.28 baseline, supports RHEL 9+, Ubuntu 22.04+, Debian 12+) or `manylinux2014_x86_64` (glibc 2.17, adds RHEL 8 + CentOS 7)
- **OCaml in container**: install via opam binary tarball (no system package), then `opam install dune cohttp-eio ...` (slow first build, cache via Docker layer)
- **Auditwheel**: scans `par_capi.so` for external lib refs, bundles any non-glibc deps, tags wheel as `manylinux_2_28_x86_64`
- **Result**: `par_runtime-0.5.0-cp311-cp311-manylinux_2_28_x86_64.whl`

| Pros | Cons |
|------|------|
| Max portability (1 wheel covers ~95% Linux servers) | OCaml 5.4 build inside manylinux container is nontrivial — opam root + 20 deps to install |
| Industry standard, well-documented | macOS wheels need separate `cibuildwheel` setup (this option is Linux-only) |
| `auditwheel check` is a free acceptance test | First CI build will be slow (~10 min for opam install) |
| PyPI users get `pip install par-runtime` and it "just works" on any modern Linux | |

### Option B: cibuildwheel (wrapper around manylinux)

[cibuildwheel](https://cibuildwheel.readthedocs.io/) is the standard tool for building Python wheels with native code across Python versions × platforms × architectures.

- Config in `pyproject.toml`:
  ```toml
  [tool.cibuildwheel]
  build = "cp311-*"
  skip = "*-musllinux_*"
  before-build = "opam install par_cli --deps-only -y && opam exec -- dune build lib/ffi/par_capi.so"
  ```
- GitHub Action `pypa/cibuildwheel` runs the matrix, produces 1 wheel per platform/Python combo.

| Pros | Cons |
|------|------|
| Less yaml to write than raw manylinux | Still requires OCaml setup per manylinux flavor |
| Handles macOS + Linux in one tool | OPAM-based build doesn't fit cibuildwheel's "compile native code" model cleanly |
| Battle-tested, used by numpy/cryptography/pillow/etc. | May fight OCaml's effect-based IO library |

### Option C: Pinned ubuntu-22.04 + setuptools upgrade (minimal fix)

Just add 1 line to existing workflow + pin runner OS:
```yaml
- name: Upgrade setuptools (PEP 621 support)
  run: pip install --upgrade setuptools wheel
```

| Pros | Cons |
|------|------|
| 1-line fix, lowest risk | Baseline still glibc 2.35 (excludes RHEL 8) |
| Fast to implement (minutes) | Doesn't address systemic issue, just current symptoms |
| No new tooling | Next distro baseline shift bites again |

### Option D: Local CI dry-run via `act`

Use [act](https://github.com/nektos/act) to run GitHub Actions workflows locally in Docker before pushing.

```bash
act -W .github/workflows/pypi-publish.yml \
    --secret-file <(echo "PYPI_TOKEN=...") \
    --container-architecture linux/amd64
```

| Pros | Cons |
|------|------|
| Iteration in seconds, not minutes | `act` doesn't perfectly emulate GitHub runners |
| Catches UNKNOWN-name-style bugs locally | Doesn't help with portability (still ubuntu-22.04 baseline) |
| Works with existing workflows unchanged | Docker-in-Docker needed for manylinux |

---

## 4. Recommendation: A + D

**A (manylinux + auditwheel)** for portability — solves the underlying "doesn't run on most Linux" problem.

**D (local dry-run)** for process discipline — catches future UNKNOWN-style bugs before they hit CI.

Skip B (too much abstraction for our OCaml setup), C-only (band-aid, doesn't fix systemic issue).

### Why not just C

Option C unblocks v0.4.11 in 12 minutes, but:
- Doesn't fix #2 in section 2 (no platform-matrix test)
- Doesn't fix #3 (ubuntu-22.04 will itself age out — same problem in 2027)
- Doesn't fix #5 (manual QA without isolation)
- Sets precedent: "1-line fix is enough", then P0 #4 happens in v0.5.x

The systemic issue is that we have **no end-to-end test gate**. Option A addresses that via `auditwheel check` + the implicit "works on manylinux container = works on everything newer" guarantee.

---

## 5. Acceptance Criteria (MUST pass before any future PyPI upload)

These are the contract. v0.5.0 release pipeline phase is not done until all pass.

### Build

- [ ] Wheel filename matches `par_runtime-{version}-cp311-cp311-manylinux_2_28_x86_64.whl` (not `UNKNOWN-0.0.0`, not `py3-none-any`)
- [ ] `auditwheel check` exits 0
- [ ] Wheel size > 1 MB (sanity check that .so is included)

### Contents

- [ ] `unzip -l wheel.whl` shows `par_runtime/lib/par_capi.so`
- [ ] `unzip -l wheel.whl` shows `par_runtime/__init__.py`, `_ffi.py`, `runtime.py`, `py.typed`

### Install matrix (each on fresh container)

- [ ] Debian 12 (glibc 2.36): `pip install` + `import par_runtime` + `Runtime(config)` init succeeds
- [ ] Ubuntu 22.04 LTS (glibc 2.35): same
- [ ] Ubuntu 24.04 LTS (glibc 2.39): same
- [ ] RHEL 9 (glibc 2.34): same (optional, can defer if manylinux_2_28 used)
- [ ] macOS arm64 (CI runner): same

### Functional

- [ ] `Runtime(config_json)` returns Runtime object (no exception)
- [ ] `Runtime.register_tool(name, desc, schema)` succeeds
- [ ] `Runtime.close()` exits cleanly
- [ ] `__version__` attribute matches the tag

### Process

- [ ] New `release-acceptance.yml` workflow runs after build, before PyPI upload
- [ ] Acceptance workflow fails → no PyPI upload happens
- [ ] Local dry-run via `act` documented in `docs/rules/release.md`

### Backward compatibility

- [ ] `install.sh` continues to work (not affected by wheel changes)
- [ ] opam-repo PR path unchanged (opam is source-based)
- [ ] GH Release binaries continue to ship (with ubuntu-22.04 baseline as v0.4.10 fixed)

---

## 6. Migration Plan (v0.5.0 Phase 1)

### Wave 1: Stop the bleeding (Day 1, 1-2 hours)

1. User yanks `par-runtime==0.4.8` and `==0.4.9` from PyPI (already broken)
2. User deletes `par_runtime-*.whl` assets from v0.4.8 / v0.4.9 / v0.4.10 GH Releases (cleanup)
3. Add prominent note to README: "PyPI install broken until v0.5.0. Use install.sh for now."
4. Update `docs/rules/release.md` with the postmortem link

### Wave 2: Acceptance test workflow (Day 2-3)

5. Create `.github/workflows/release-acceptance.yml`:
   - Trigger: workflow_run on `pypi-publish.yml` completed
   - Spin up matrix of containers (Debian 12, Ubuntu 22.04, Ubuntu 24.04)
   - In each: `pip install <wheel-from-gh-release>` + run acceptance test script
   - If any fails: post comment on release, mark as broken, do NOT auto-upload to PyPI
6. Create `scripts/release-acceptance-test.py` (single source of truth for the install test)

### Wave 3: manylinux build (Day 4-5)

7. Create `docker/manylinux-ocaml-5.4/Dockerfile`:
   ```dockerfile
   FROM quay.io/pypa/manylinux_2_28_x86_64
   RUN curl -fsSL https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh | bash
   RUN opam init -a --disable-sandboxing
   RUN opam switch create 5.4.0 5.4.0
   RUN eval $(opam env --switch=5.4.0) && opam install dune cohttp-eio ...
   ```
8. Modify `pypi-publish.yml` to build inside the container, then `auditwheel repair`
9. Output: `par_runtime-{version}-cp311-cp311-manylinux_2_28_x86_64.whl`

### Wave 4: Local dry-run (Day 6)

10. Document `act` setup in `docs/rules/release.md`
11. Create `scripts/release-dry-run.sh` that runs pypi-publish.yml locally
12. Add pre-push git hook (optional) for `make test` + `scripts/release-dry-run.sh`

### Wave 5: First v0.5.0 release (Day 7)

13. Tag `v0.5.0-beta.YYYYMMDD` → triggers full new pipeline
14. Acceptance workflow runs → if green, manually `twine upload` the beta wheel
15. Beta user (you) installs from PyPI on real Debian 12 / Ubuntu 22.04 box
16. If passes for 24 hours → tag `v0.5.0` stable → CI uploads to PyPI

---

## 7. Estimated Effort

| Wave | Effort | Risk |
|------|--------|------|
| 1 (cleanup) | 1-2 hours | Low (docs + manual ops) |
| 2 (acceptance test) | 1 day | Medium (CI workflow design) |
| 3 (manylinux Docker) | 1-2 days | High (OCaml in manylinux is fiddly) |
| 4 (local dry-run) | 0.5 day | Low |
| 5 (first release) | 0.5 day + 1 day soak | Medium (first end-to-end test) |
| **Total** | **~5 days** | |

If Wave 3 (manylinux) proves too hard, fallback to Option C + D (pin ubuntu-22.04 + setuptools upgrade + acceptance tests). Still much better than current state.

---

## 8. Open Questions

1. **Python version matrix**: Should we build for cp38, cp39, cp310, cp311, cp312, cp313? Or just cp311 (current)? `par_capi.so` is Python-version-agnostic (ctypes), so technically `py3-none-any` is correct — but `manylinux` tags are usually coupled with cp3xx. Need to test if `manylinux_2_28_x86_64` (no cp tag) works.
2. **macOS wheel**: cibuildwheel handles macOS natively. manylinux is Linux-only. For macOS, current release.yml binary path works (install.sh). Do we need a `par_runtime-X.Y.Z-py3-none-macosx_*_universal2.whl` too? Or document "macOS users use install.sh"?
3. **ARM64 (aarch64)**: manylinux has `_aarch64` variants. Worth building? Most production Linux is still x86_64. M-series Mac users use install.sh.
4. **PyPI auto-upload vs manual twine**: Currently `pypi-publish.yml` only uploads to GH Release, manual `twine upload` after. Switch to auto-upload via PyPI API token in CI secrets? Pro: less manual. Con: broken wheel auto-uploads if acceptance fails.

---

## 9. References

- [manylinux definition](https://github.com/pypa/manylinux)
- [auditwheel docs](https://auditwheel.readthedocs.io/)
- [cibuildwheel docs](https://cibuildwheel.readthedocs.io/)
- [PyPI OIDC trusted publishers](https://docs.pypi.org/trusted-publishers/) (alternative to API tokens)
- [PEP 621](https://peps.python.org/pep-0621/) (`[project]` table in pyproject.toml, requires setuptools >= 61)

---

**Decision needed from user before Wave 2**:
- A+D (recommended), C+D (minimal), or A-only, B+D
- Python version matrix
- macOS wheel scope
- ARM64 scope
- Auto vs manual PyPI upload

Once decided, this doc becomes the v0.5.0 Phase 1 plan and work can begin.
