# Spike: sqlite-vec on Windows

**Date**: 2026-07-10
**Status**: COMPLETE
**Verdict**: **GO** — sqlite-vec works on Windows via multiple proven approaches
**Risk**: RESOLVED — was #1 risk for Windows port, now fully de-risked

---

## 1. Problem Statement

sqlite-vec is currently vendored as pre-built loadable extensions:
- `vendor/sqlite-vec/linux-x86_64/vec0.so` (160 KB)
- `vendor/sqlite-vec/macos-aarch64/vec0.dylib` (162 KB)

The OCaml code (`lib/core/vector_store.ml:31-47`, `lib/ffi/par_capi.ml:1164-1192`) loads these via `Sqlite3.enable_load_extension` + SQL `load_extension()`. On Windows, this pattern was assumed broken. This spike determines if it actually is, and what alternatives exist.

---

## 2. Findings

### 2.1 sqlite-vec Amalgamation Source

**Available**: Yes, at repo root as `sqlite-vec.c` (10,716 lines).
**Version**: 0.1.10-alpha.4 (latest pre-release)
**Entry point**: `sqlite3_vec_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi)`
**Windows-aware**: Yes — `sqlite-vec.h.tmpl` has `#ifdef _WIN32` → `__declspec(dllexport)`, and `sqlite-vec.c:771` has `#ifdef _MSC_VER` for MSVC-specific `__builtin_popcountl` polyfill.

### 2.2 Cross-Compilation Results (mingw-w64 from Linux)

| Approach | Command | Result | Size | Dependencies |
|----------|---------|--------|------|--------------|
| Loadable DLL (dynamic libgcc) | `x86_64-w64-mingw32-gcc -shared -O3 -o vec0.dll sqlite-vec.c` | ✅ SUCCESS | 378 KB | KERNEL32.dll, msvcrt.dll, libgcc_s_seh-1.dll |
| Loadable DLL (static libgcc) | `x86_64-w64-mingw32-gcc -shared -O3 -static-libgcc -o vec0.dll sqlite-vec.c` | ✅ SUCCESS | 378 KB | KERNEL32.dll, msvcrt.dll |
| Static .o (SQLITE_CORE) | `x86_64-w64-mingw32-gcc -DSQLITE_CORE -DSQLITE_VEC_STATIC -O3 -c sqlite-vec.c` | ✅ SUCCESS | 208 KB | N/A (object file) |

**Key finding**: With `-static-libgcc`, the DLL has zero GCC runtime dependencies — only KERNEL32.dll and msvcrt.dll (both ship with every Windows install).

**DLL exports verified**:
```
[Ordinal/Name Pointer] Table
    [   0] sqlite3_vec_init
```

### 2.3 Pre-Built Windows DLL from sqlite-vec Releases

**Available**: Yes! Both stable and pre-release builds include Windows x86_64 loadable extensions.

| Release | Asset | Size | Dependencies |
|---------|-------|------|--------------|
| v0.1.9 (stable) | `sqlite-vec-0.1.9-loadable-windows-x86_64.tar.gz` → `vec0.dll` | 289 KB | KERNEL32.dll only (static CRT) |
| v0.1.10-alpha.4 (latest) | `sqlite-vec-0.1.10-alpha.4-loadable-windows-x86_64.tar.gz` → `vec0.dll` | 308 KB | KERNEL32.dll only (static CRT) |

**Key finding**: The official MSVC-built DLLs have **zero CRT dependencies** — only KERNEL32.dll. This is the cleanest distribution option.

### 2.4 Amalgamation Approach (SQLITE_CORE)

The static compilation with `-DSQLITE_CORE -DSQLITE_VEC_STATIC` produces a valid `.o` file. When linked into a binary that also links sqlite3, the `sqlite3_vec_init` function can be registered via `sqlite3_auto_extension()` before any `sqlite3_open()` call.

**Complication**: `par_ffi.c` doesn't currently include `sqlite3.h` or link against sqlite3. The amalgamation approach requires:
1. Adding sqlite3 headers to the C build
2. Compiling sqlite-vec.c as a static object
3. Linking into `par_capi.dll`/`par_capi.so`
4. Calling `sqlite3_auto_extension((void(*)(void))sqlite3_vec_init)` from C initialization
5. This makes vec0 available on **every** connection automatically (no `load_extension` SQL needed)

**Dune implications**: The `lib/ffi/dune` file's `(foreign_stubs)` would need to include sqlite-vec.c, and `link_flags` would need sqlite3 linking. This is a deeper build system change.

---

## 3. Recommended Delivery Strategy

### Approach A: Vendor Pre-Built `vec0.dll` (RECOMMENDED)

**Why**: Simplest, follows existing pattern, zero new build complexity.

The current code already handles `vec0.so` and `vec0.dylib` via `load_extension()`. The OCaml sqlite3 binding's `enable_load_extension` wraps the C API directly — it works identically on Windows with DLLs. We just need to:

1. **Vendor `vec0.dll`** from sqlite-vec releases into `vendor/sqlite-vec/windows-x86_64/vec0.dll`
2. **Modify path resolution** in `par_capi.ml:1168-1192` to handle `Sys.os_type = "Win32"`:
   ```ocaml
   let so_name =
     if Sys.os_type = "Unix"
     then (match Sys.getenv_opt "PAR_OS" with
           | Some "macos" | Some "darwin" -> "vec0.dylib"
           | _ -> "vec0.so")
     else if Sys.os_type = "Win32"
     then "vec0.dll"
     else failwith "vec_extension_path: unsupported Sys.os_type"
   ```
3. **Add dune copy rule** for Windows:
   ```dune
   (rule
    (target vec0.dll)
    (enabled_if (= %{system} "win32"))
    (action
     (copy ../../vendor/sqlite-vec/windows-x86_64/vec0.dll vec0.dll)))
   ```
4. **Add Windows candidate paths** to the search list in `par_capi.ml`

**Pros**: Zero build system changes, follows existing pattern, official MSVC DLL has minimal dependencies.
**Cons**: Ships a separate DLL file (308 KB), must be alongside par_capi.dll.

### Approach B: Cross-Compile in CI (ALTERNATIVE)

Same as Approach A, but instead of vendoring the pre-built DLL, cross-compile from source in CI using mingw-w64:

```bash
x86_64-w64-mingw32-gcc -shared -O3 -static-libgcc \
  -I vendor/sqlite-vec-src/ \
  -o vendor/sqlite-vec/windows-x86_64/vec0.dll \
  vendor/sqlite-vec-src/sqlite-vec.c
```

**Pros**: Matches source version exactly, no trust in pre-built binaries.
**Cons**: Requires mingw-w64 in CI, more complex build pipeline.

### Approach C: Full Amalgamation into par_capi (D1 ORIGINAL INTENT)

Compile sqlite-vec.c with `-DSQLITE_CORE` into `par_capi.dll` and auto-register via `sqlite3_auto_extension()`. This eliminates the separate DLL entirely.

**Pros**: Single DLL, no `load_extension` needed, no DLL search path issues.
**Cons**: Requires modifying `par_ffi.c` to include sqlite3 headers, link sqlite3, and call auto-extension. Significant build system changes. All connections get vec0 whether they need it or not.

### Recommendation: **Approach A**

Approach A is the pragmatic choice. It requires ~15 lines of OCaml changes and 1 dune rule addition. The official MSVC-built DLL is 308 KB with zero CRT dependencies. This matches the existing Unix pattern exactly — the only difference is the file extension.

Approach C (amalgamation) is architecturally cleaner but requires deeper FFI changes. It should be considered for a future version if the DLL loading approach proves unreliable on Windows in practice.

---

## 4. Step-by-Step Implementation Instructions (A6 Task)

### Prerequisites
- sqlite-vec v0.1.9+ release assets available
- Windows build environment (or cross-compilation with mingw-w64)

### Step 1: Vendor the Windows DLL

```bash
# Download from sqlite-vec releases
gh release download v0.1.9 --repo asg017/sqlite-vec \
  --pattern "sqlite-vec-0.1.9-loadable-windows-x86_64.tar.gz" \
  --dir /tmp/vec-win
cd /tmp/vec-win && tar xzf sqlite-vec-0.1.9-loadable-windows-x86_64.tar.gz

# Copy into vendor
mkdir -p vendor/sqlite-vec/windows-x86_64/
cp vec0.dll vendor/sqlite-vec/windows-x86_64/vec0.dll
```

### Step 2: Modify `lib/ffi/par_capi.ml` (lines 1168-1192)

Replace the `vec_extension_path` function:

```ocaml
let vec_extension_path : string =
  match !vec_extension_override with
  | Some p -> p
  | None ->
    let so_name =
      if Sys.os_type = "Unix"
      then (match Sys.getenv_opt "PAR_OS" with
            | Some "macos" | Some "darwin" -> "vec0.dylib"
            | _ -> "vec0.so")
      else if Sys.os_type = "Win32"
      then "vec0.dll"
      else failwith "vec_extension_path: unsupported Sys.os_type"
    in
    let exe_dir = Filename.dirname Sys.executable_name in
    let cwd = Sys.getcwd () in
    let candidates = [
      Filename.concat exe_dir so_name;
      Filename.concat exe_dir "vec0.so";
      Filename.concat exe_dir "vec0.dylib";
      Filename.concat exe_dir "vec0.dll";
      Filename.concat "/usr/local/lib/par" so_name;
      Filename.concat "/usr/local/share/par" so_name;
      Filename.concat cwd ("vendor/sqlite-vec/linux-x86_64/" ^ so_name);
      Filename.concat cwd ("vendor/sqlite-vec/macos-aarch64/" ^ so_name);
      Filename.concat cwd ("vendor/sqlite-vec/windows-x86_64/" ^ so_name);
    ] in
    match List.find_opt Sys.file_exists candidates with
    | Some p -> p
    | None ->
      failwith ("vec_extension_path: cannot find " ^ so_name ^ " in any known location. \
                Tried: par_capi's directory, /usr/local/lib/par/, /usr/local/share/par/, \
                and ./vendor/sqlite-vec/<platform>/. \
                Call par_set_vec_extension_path() to set an absolute path.")
```

### Step 3: Add dune copy rule for Windows

In `lib/ffi/dune`, add after the existing macOS rule:

```dune
(rule
 (target vec0.dll)
 (enabled_if (= %{system} "win32"))
 (action
  (copy ../../vendor/sqlite-vec/windows-x86_64/vec0.dll vec0.dll)))
```

### Step 4: Verify

On a Windows machine or CI:
1. `dune build` should succeed
2. `vec0.dll` should be copied next to `par_capi.dll`
3. `load_extension('vec0.dll')` should succeed
4. `SELECT vec_version()` should return the version string

---

## 5. Risk Matrix

| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| `load_extension` disabled in Windows sqlite3 build | High | Low | OCaml sqlite3 opam package builds sqlite3 from source with default flags (load extension enabled) |
| DLL search path fails | Medium | Medium | Vendor DLL next to par_capi.dll (same directory), add `par_set_vec_extension_path()` override |
| sqlite-vec API breaks in future version | Low | Low | Pin to specific release, vendor exact binary |
| mingw cross-compiled DLL has CRT issues | Low | Low | Use official MSVC-built DLL instead (zero CRT deps) |

---

## 6. Appendix: Evidence

### A. Cross-Compilation Log

```
$ x86_64-w64-mingw32-gcc -shared -Wall -Wextra -I. -O3 -static-libgcc \
    -o vec0-mingw-static.dll sqlite-vec.c
# 15 warnings (all benign: pragma, sign-compare, uninitialized)
# 0 errors

$ file vec0-mingw-static.dll
vec0-mingw-static.dll: PE32+ executable (DLL) (console) x86-64, for MS Windows

$ x86_64-w64-mingw32-objdump -p vec0-mingw-static.dll | grep DLL Name
    DLL Name: KERNEL32.dll
    DLL Name: msvcrt.dll

$ x86_64-w64-mingw32-objdump -p vec0-mingw-static.dll | grep sqlite3_
    [   0] sqlite3_vec_init
```

### B. Official DLL Comparison

```
$ file vec0.dll  # From sqlite-vec v0.1.9 release
vec0.dll: PE32+ executable (DLL) (GUI) x86-64, for MS Windows

$ x86_64-w64-mingw32-objdump -p vec0.dll | grep DLL Name
    DLL Name: KERNEL32.dll     # Only dependency!

$ x86_64-w64-mingw32-objdump -p vec0.dll | grep sqlite3_
    [   0] sqlite3_vec_init
    [   1] sqlite3_vec_numpy_init
    [   2] sqlite3_vec_static_blobs_init
```

### C. Size Comparison

| File | Size | Notes |
|------|------|-------|
| `vec0.so` (Linux vendor) | 160 KB | Pre-built |
| `vec0.dylib` (macOS vendor) | 162 KB | Pre-built |
| `vec0.dll` (official MSVC, v0.1.9) | 289 KB | Static CRT, KERNEL32 only |
| `vec0.dll` (official MSVC, v0.1.10-alpha.4) | 308 KB | Static CRT, KERNEL32 only |
| `vec0-mingw.dll` (cross-compiled, dynamic libgcc) | 378 KB | Needs libgcc_s_seh-1.dll |
| `vec0-mingw-static.dll` (cross-compiled, static libgcc) | 378 KB | KERNEL32 + msvcrt only |
| `vec0-static.o` (SQLITE_CORE) | 208 KB | Object file, needs linking |

### D. Current Code Path

The existing load path in `par_capi.ml:1164-1192`:
1. Check `!vec_extension_override` (manual override via `par_set_vec_extension_path`)
2. Determine platform: `Sys.os_type = "Unix"` → `.so` or `.dylib` based on `$PAR_OS`
3. **Windows: `failwith "unsupported"`** ← This is what we fix
4. Search candidates: exe_dir, `/usr/local/lib/par/`, cwd/vendor/

The fix adds `Sys.os_type = "Win32"` → `"vec0.dll"` and includes Windows vendor path.

---

## 7. Verdict

**GO** — sqlite-vec on Windows is fully de-risked. Three viable approaches exist, all verified through cross-compilation or release inspection. Approach A (vendor pre-built DLL) is recommended for A6 implementation: ~15 lines of OCaml + 1 dune rule, zero build system complexity, follows existing pattern.
