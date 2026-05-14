# `boringssl-zig` — Project Specification

You are the build engineer for `boringssl-zig`, a fork of Google's BoringSSL that adds a pure Zig build system. Your job is to maintain this project as upstream BoringSSL evolves.

This document is the source of truth. When the spec is ambiguous, ask before guessing. When the spec conflicts with reality (upstream changed, a Zig API moved), surface the conflict and propose a fix — do not silently deviate.

---

## 1. Mission

Produce a Zig package that:

1. Lives as a **fork** of `google/boringssl`. Upstream files sit at the repo root; our additions sit alongside them under non-conflicting names.
2. Builds `libcrypto.a`, `libssl.a`, `libpki.a` from that source using only `zig build` (no CMake, no Bazel).
3. Cross-compiles to any target Zig supports (macOS aarch64/x86_64, Linux aarch64/x86_64, Windows x86_64, WASM32-WASI).
4. Is consumable by any other Zig project via `zig fetch --save` + `b.dependency().artifact("ssl")`.
5. Tracks upstream BoringSSL via plain `git merge upstream/main`, run by hand or by the weekly GitHub Action.

---

## 2. Architecture decisions

### 2.1 Upstream tracking: fork at root, sync via `git merge`

- Upstream files live at the repo **root** (`crypto/`, `ssl/`, `pki/`, `include/`, `gen/`, …) exactly as in `google/boringssl`.
- Our additions sit alongside them at the root (`build.zig`, `build.zig.zon`) and in fresh subdirectories (`src/`, `tests/`, `scripts/`, `.github/workflows/ci.yml`, `.github/workflows/sync-upstream.yml`).
- The two files where names *would* collide with upstream are renamed: our README is `README-zig.md`, our license file is `LICENSE-zig`. Upstream's `README.md` and `LICENSE` are kept untouched.
- Upstream sync is plain `git fetch upstream && git merge upstream/main`, wrapped in `scripts/sync-upstream.sh`. The first run of that script adds the `upstream` remote; subsequent runs just fetch+merge.
- Why this layout (and not `git subtree` under `vendor/boringssl/`): the standard merge workflow keeps upstream commit SHAs visible, avoids `git subtree`'s squash artifacts, and uses only standard git. Conflicts are still rare in practice — upstream BoringSSL has never shipped a `build.zig` and never will.

### 2.2 Build driver: read source manifest, never hardcode

- BoringSSL upstream maintains `gen/sources.json` (pre-generated and checked in) as the canonical list of source files, asm files per target, and headers.
- `build.zig` parses this file at build time via `@embedFile("gen/sources.json")` + `std.json`.
- Schema (top-level keys we use): `bcm`, `crypto`, `ssl`, `pki`. Each has `srcs`, `hdrs`, `internal_hdrs`, `asm`, `nasm`.
- **Never hardcode source file lists.** This is the single most important rule for keeping sync painless.
- Because `gen/sources.json` is checked in, Go pregeneration is **not** required at build time.

### 2.3 Go is an optional regeneration tool, not a build dependency

- BoringSSL ships Go tooling under `util/pregenerate/` that regenerates the contents of `gen/` (including `err_data.cc`, perlasm `.S` files, and `sources.json`).
- All outputs of that tool are pre-committed under `gen/`, so a clean build needs only Zig.
- Go is required only when (a) regenerating these files after editing inputs, or (b) verifying upstream `gen/` matches `build.json` after a sync.

### 2.4 Output contract

- Three static libraries: `libcrypto.a`, `libssl.a`, `libpki.a`.
- Public headers (`include/openssl/*.h`) installed via `lib.installHeadersDirectory(...)` so consumers automatically get `#include <openssl/ssl.h>` working after `linkLibrary`.
- An optional Zig wrapper module `src/root.zig` exposing minimal `extern fn` declarations.
- Installed under `zig-out/lib/` and `zig-out/include/`.

### 2.5 Zig version

- Target Zig `0.16.0` (current stable) and recent `0.17.0-dev` nightly.
- Use the modern build API: `b.addLibrary(.{ .linkage = .static, .root_module = ... })`, not the deprecated `b.addStaticLibrary(...)`.
- Module operations (`addCSourceFiles`, `addIncludePath`, `linkLibrary`, `linkSystemLibrary`) live on `*std.Build.Module`. `installHeadersDirectory` lives on `*std.Build.Step.Compile`.

---

## 3. Repository layout

```
boringssl-zig/
├── README.md                  # upstream BoringSSL README — DO NOT EDIT
├── LICENSE                    # upstream BoringSSL license — DO NOT EDIT
├── README-zig.md              # our README (consumer + maintainer guide)
├── LICENSE-zig                # MIT for our build system
├── CLAUDE.md                  # this file
├── build.zig
├── build.zig.zon
├── .gitignore                 # upstream's; we appended zig-out/ + .zig-cache/
├── src/root.zig               # minimal Zig wrapper module
├── tests/smoke.zig            # links libssl, calls RAND_bytes
├── scripts/sync-upstream.sh   # git fetch upstream && git merge
├── .github/workflows/
│   ├── branch-time.yml        # upstream's, untouched
│   ├── ci.yml                 # ours: build verification on every push
│   └── sync-upstream.yml      # ours: weekly cron, opens merge PR
└── (rest of the BoringSSL tree at the root: crypto/, ssl/, pki/,
   include/, gen/, third_party/, util/, …)
```

---

## 4. Conventions

- **Never edit upstream files.** Anything that exists in `google/boringssl@main` is read-only. If you need a patch, store it under `patches/` and apply from `scripts/sync-upstream.sh` after the merge. Document the rationale in the patch's header comment.
- All file paths in `build.zig` use `b.path(...)`, never raw string literals.
- All conditional behavior driven by `b.option(...)` with sensible defaults.
- Read source lists from `gen/sources.json` — no hardcoded enumeration.
- Use `b.addLibrary` (0.14+ API). Do not use `b.addStaticLibrary` or `b.addSharedLibrary`.
- Use `lib.installHeadersDirectory(...)` so consumers don't manually `addIncludePath`.
- Keep cross-compilation as a first-class case: no host-specific assumptions in `build.zig` beyond what `target.result.os.tag` lets you switch on.
- Our additions must use names that don't collide with upstream files. If upstream introduces a name we already use, rename ours.

---

## 5. Forbidden actions

- Do not modify any file owned by upstream (i.e., anything that exists in `google/boringssl@main`).
- Do not vendor BoringSSL via `cp -r`, ZIP download, or git submodule. The fork+merge workflow is the source of truth.
- Do not hardcode source file lists, asm file lists, or cflags in `build.zig`. Parse `gen/sources.json`.
- Do not introduce CMake, Bazel, Make (beyond a thin convenience `Makefile` if desired), or any other build system. Only `build.zig`.
- Do not add hard build-time dependencies beyond Zig. (Go is optional, only for regenerating `gen/`.)
- Do not weaken or remove the CI matrix without justification. Cross-compilation coverage is non-negotiable.

---

## 6. Versioning

Tags follow `v0.YYYYMMDD.0` matching the date of the upstream commit being merged. Bump the patch component (`.1`, `.2`) only if you ship build-system-only fixes between upstream syncs.

---

## 7. When upstream sync breaks the build

A merge occasionally breaks compilation. Triage in this order:

1. **`gen/sources.json` schema changed.** Re-read the file, adjust the parser at the top of `build.zig`.
2. **New top-level directory introduced** that contains build inputs. Add it to `build.zig.zon`'s `.paths`.
3. **C++ standard requirement bumped** (e.g., C++17 → C++20). Update cflags in `build.zig`.
4. **New compile flag required.** Cross-check upstream's `CMakeLists.txt` for `add_compile_definitions` / `target_compile_definitions` changes.
5. **A merge conflict** on a file we own. Resolve in our favor (our build files are the source of truth for the build system).

If a sync is unfixable in one sitting, `git reset --hard ORIG_HEAD` to revert the merge, file an issue, and fix forward later. Never ship a broken `main`.
