# zoptia0boringssl

A pure-Zig build of [Google's BoringSSL](https://github.com/google/boringssl).

This repository is a **fork** of `google/boringssl`: upstream files live at
the repo root unchanged, and our additions (`build.zig`, `src/`, `tests/`,
`scripts/`, `.github/workflows/ci.yml`, `.github/workflows/prebuilt.yml`)
sit alongside them. Upstream sync is plain `git fetch upstream && git merge`.

The build driver parses BoringSSL's own [`gen/sources.json`](gen/sources.json)
manifest at build time — no source list is duplicated here, so upstream
churn is mostly absorbed without touching `build.zig`.

> Note: BoringSSL's own README is preserved at [`README.md`](README.md).
> BoringSSL's license is at [`LICENSE`](LICENSE). The build-system additions
> in this fork are MIT-licensed; see [`LICENSE-zig`](LICENSE-zig).

## Quick start (consumer)

Add this package to your project:

```sh
zig fetch --save=boringssl git+https://github.com/zoptia/zoptia0boringssl#v0.20260513.0
```

Then in your `build.zig`:

```zig
const boringssl = b.dependency("boringssl", .{
    .target = target,
    .optimize = optimize,
});

const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
// Make `@import("boringssl")` resolve to our wrapper module.
exe_mod.addImport("boringssl", boringssl.module("boringssl"));

const exe = b.addExecutable(.{ .name = "myapp", .root_module = exe_mod });
exe.linkLibrary(boringssl.artifact("ssl"));     // pulls in libcrypto too
// Headers under <openssl/...> are now visible — no extra addIncludePath needed.
```

If you want only `libcrypto`, link `boringssl.artifact("crypto")` instead. A
third artifact, `pki`, is also available.

The wrapper module gives you:

```zig
const bssl = @import("boringssl");
var buf: [32]u8 = undefined;
_ = bssl.c.RAND_bytes(&buf, buf.len);
```

The wrapper currently exposes only a tiny set of `extern fn` declarations
(`RAND_bytes`, `OpenSSL_version`). BoringSSL's headers are too macro-heavy
for `zig translate-c` to handle reliably, so the recommended pattern for
broader use is to declare the functions you need yourself — link
`boringssl.artifact("ssl")` and the symbols are available.

## Supported targets

CI verifies builds on `ubuntu-latest` and `macos-latest`, including:

- `aarch64-macos`, `x86_64-macos`
- `aarch64-linux-gnu`, `x86_64-linux-gnu`
- `wasm32-wasi` (with `-Dasm=false`)
- `x86_64-windows-gnu` (with `-Dasm=false`; see Windows note)

Other Zig targets should generally work; please open an issue if not.

### Build options

| Flag | Default | Description |
|------|---------|-------------|
| `-Dtarget=<triple>` | host | Standard Zig cross target |
| `-Doptimize=<mode>` | Debug | ReleaseFast / ReleaseSafe / ReleaseSmall |
| `-Dasm=true\|false` | `true` | Include perlasm-generated assembly |
| `-Dprefix=<path>` | (none) | Skip source compilation; use prebuilt libs at `<path>/lib` + headers at `<path>/include` |
| `-Dfips=…` | (reserved) | FIPS module is not supported yet |

#### `-Dprefix` for cached / system / patched builds

If you already have `lib{crypto,ssl,pki}.a` (or `{crypto,ssl,pki}.lib` on
MSVC) and `include/openssl/*.h` somewhere on disk, point `-Dprefix=<path>`
at the parent directory and the build will skip compiling BoringSSL
entirely — it just re-exports the existing archives behind the same
`b.dependency().artifact("ssl")` interface. Useful for:

- Local caching (one slow source build, many fast incremental ones)
- Pinning to a system-supplied or distro-supplied build
- Linking against a patched BoringSSL you maintain elsewhere

Layout expected at `<path>/`:

```
lib/
  libcrypto.a   (or crypto.lib  on -windows-msvc)
  libssl.a      (or ssl.lib     on -windows-msvc)
  libpki.a      (or pki.lib     on -windows-msvc)
include/openssl/*.h
```

Source mode and prefix mode produce the same `zig-out/` layout, so any
downstream `build.zig` is identical for both.

### Windows note

For `x86_64-windows`, BoringSSL's perlasm output is in NASM syntax and Zig
does not bundle NASM. Build with `-Dasm=false` for a portable build (slower
crypto), or install NASM in `PATH` and the build will shell out to it. ARM
Windows uses GAS-format `.S` files and works without external tools.

For `x86_64-windows-msvc`, **`crypto.lib`/`ssl.lib`/`pki.lib` build fine
and are usable from MSVC consumers**, but Zig 0.16's bundled libcxx
clashes with `<typeinfo>` from the MSVC SDK when linking a Zig-side
executable against them — a `using ::type_info;` collision via
libcxxabi's `cxa_exception.cpp`. Our CI builds `windows-msvc` but does
not run the smoke test there. C/C++ consumers using `cl.exe`/`link.exe`
do **not** hit this — they link the `.lib` files with the MSVC C++
runtime, which is what BoringSSL was designed for on Windows.

### Mobile platform support

#### Android — via the musl tarballs (no NDK required)

The two `linux-musl-{aarch64,x86_64}` prebuilt tarballs **work as
drop-ins for Android apps**, even though they were never built against
the NDK:

- The release-mode `.a` only references standard POSIX, C, pthread,
  and `operator new`/`operator delete` symbols. Android's Bionic libc
  + libc++ provide every one of them with the same C calling
  convention and (since they sit on the same Linux/AArch64 kernel ABI)
  the same syscall behavior.
- Build:

  ```sh
  # On any host that can do Zig cross-compile
  zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast
  ```

- Link inside an Android NDK project: feed `libcrypto.a` / `libssl.a`
  to `ld` (or `add_library(... IMPORTED STATIC)`) like any other
  static lib. No NDK headers, no Zig build, no Rust toolchain on the
  consumer side.

Caveat: this is symbol-analysis correctness, not field-tested at
runtime on a device — if you do verify on a phone, please open an
issue with the result.

#### iOS — Xcode SDK still required

iOS lacks an equivalent "swap the libc" escape hatch: it's not Linux,
not Mach-O-compatible with macOS in the way the linker enforces, and
Zig 0.16/0.17 can't fully suppress its bundled libcxx headers even
with `link_libcpp = false` + `-nostdinc++`, so the SDK's libc++ never
wins the include ordering against Zig's. The `-Dsysroot` and
`applySysroot` plumbing in `build.zig` is ready — point it at
`$(xcrun --sdk iphoneos --show-sdk-path)` once Zig's `link_libcpp`
gets stricter and you should be unblocked. iOS prebuilt tarballs are
not in the current release.

#### `-Dsysroot=<path>` for bring-your-own-SDK

If you _do_ have a platform SDK and want the build to use it
(e.g. linking against system libraries on an embedded board, or for
Android-with-NDK experimentation), the option is plumbed through:

```sh
zig build -Dtarget=<triple> -Dsysroot=<path-to-sysroot>
```

`applySysroot` in `build.zig` adds `<sysroot>/usr/include/c++/v1`,
`<sysroot>/usr/include`, and `<sysroot>/usr/lib` to the include/lib
search paths, plus an Android-specific
`<sysroot>/usr/include/<triple>/` tier where the NDK keeps
arch-specific headers. The wider toolchain compatibility issues
described above still apply.

## Prebuilt downloads

Each `v0.YYYYMMDD.0` tag triggers
[`prebuilt.yml`](.github/workflows/prebuilt.yml), which uploads
per-target tarballs as assets on the corresponding GitHub Release:

```
boringssl-v0.YYYYMMDD.0-linux-x86_64.tar.gz        (glibc)
boringssl-v0.YYYYMMDD.0-linux-aarch64.tar.gz       (glibc)
boringssl-v0.YYYYMMDD.0-linux-musl-x86_64.tar.gz   (musl; doubles as Android x86_64)
boringssl-v0.YYYYMMDD.0-linux-musl-aarch64.tar.gz  (musl; doubles as Android aarch64)
boringssl-v0.YYYYMMDD.0-macos-aarch64.tar.gz
boringssl-v0.YYYYMMDD.0-windows-x86_64-gnu.tar.gz
boringssl-v0.YYYYMMDD.0-windows-x86_64-msvc.tar.gz
boringssl-v0.YYYYMMDD.0-windows-aarch64-gnu.tar.gz   (mingw ABI; MSVC ARM not yet, no runner)
boringssl-v0.YYYYMMDD.0-wasm32-wasi.tar.gz
SHA256SUMS
```

Layout inside each tarball:

```
boringssl-v0.YYYYMMDD.0-<target>/
├── lib/lib{crypto,ssl,pki}.a   (or .lib on -windows-msvc)
└── include/openssl/*.h
```

Verify with `shasum -a 256 -c SHA256SUMS`, then point a downstream
`-Dprefix=<extracted-dir>` at it (see [`-Dprefix`](#-dprefix-for-cached--system--patched-builds)
above).

## Build requirements

- **Zig 0.16+** (development tracks Zig nightly `0.17.0-dev.298+ad1b746e2`
  or newer; the `0.16.0` stable release also works).
- **Nothing else.** Go is *only* needed if you regenerate the files under
  `gen/`, which zoptia0boringssl never does at build time (they ship
  pre-generated upstream).

## Versioning

Tags follow `v0.YYYYMMDD.0`, where `YYYYMMDD` is the date of the upstream
BoringSSL commit that was merged. The `.0` patch component bumps for
build-system-only fixes between syncs (e.g., `v0.20260513.1`).

## Maintainer guide

Sync and release happen locally — there's no cron-driven server-side
automation. The flow is two commands you (or Claude Code) run in the
checkout, followed by a tag push that triggers `prebuilt.yml` server-side.

### Sync upstream and ship a release

```sh
# 1. Pull upstream into the local main branch
./scripts/sync-upstream.sh

# 2. Validate against BoringSSL's own ~3500 C++ tests in release mode
zig build -Doptimize=ReleaseFast test-all

# 3. Push main (so the tag commit is reachable on origin)
git push origin main

# 4. Tag and push — this triggers prebuilt.yml on GitHub
TAG="v0.$(date -u +%Y%m%d).0"
git tag -a "$TAG" -m "Sync upstream BoringSSL $(date -u +%Y-%m-%d)"
git push origin "$TAG"
```

`scripts/sync-upstream.sh` is idempotent: it adds an `upstream` remote on
first run if not present, then `git fetch upstream && git merge upstream/main`.
Conflicts are rare — most file paths owned by us (`build.zig`, `src/…`,
`tests/…`, `scripts/…`, `LICENSE-zig`, `README-zig.md`, `CLAUDE.md`,
`.github/workflows/{ci,prebuilt}.yml`) have names upstream doesn't use.

#### Fresh clones on a new machine

Git remotes live in the local `.git/config` and are **not** cloned with the
repo, so a fresh `git clone` only has `origin` — there is no `upstream`. You
do **not** need to add it by hand: the upstream URL is baked into
`scripts/sync-upstream.sh` (the `UPSTREAM_URL` variable), and the script adds
the remote automatically on its first run. Just run `./scripts/sync-upstream.sh`
on any new checkout and syncing works. (Git has no mechanism to ship a remote
inside the repository itself, which is exactly why the URL lives in the
script rather than in git config.)

### What `prebuilt.yml` does after the tag push

| Trigger | Action |
|---|---|
| `git push origin v0.*` | GitHub runs `prebuilt.yml`, which checks out the *tag* (not main HEAD), builds 9 target tarballs in `ReleaseFast`, runs `test-all` on every native runner, and uploads them + `SHA256SUMS` as assets on the GitHub Release for that tag |
| `workflow_dispatch` (manual UI / `gh workflow run`) | Same, but you specify the tag — useful for back-filling an old tag |

If any native job's `test-all` fails, that target's tarball isn't staged
and the publish job's dependency fails — the broken artifact never lands
on the release.

### Why this and not GitHub-side automation

Earlier the repo had `sync-upstream.yml` (weekly cron, PR + auto-tag) and
`auto-tag.yml`. They were removed because:

- Local validation runs the full `zig build test-all` on the host where
  you'd actually catch a regression first, before any commit hits CI.
- `gh pr create` from `GITHUB_TOKEN` doesn't trigger pre-merge CI
  (GitHub's anti-recursion protection), so the server-side path either
  needed a PAT or shipped without CI gating.
- For a fork this size, "run two commands and push a tag" is faster than
  reviewing an auto-generated PR.

The git workflow is still standard: `git fetch upstream && git merge`
is what `scripts/sync-upstream.sh` does, so any contributor without
Claude Code can run it by hand.

### When a sync breaks the build

Triage in this order:

1. `gen/sources.json` schema changed → fix the parser at the top of
   `build.zig`.
2. New top-level directory in upstream that holds build inputs → add it
   to `build.zig.zon`'s `.paths`.
3. New compile flag required → mirror it from `CMakeLists.txt`.
4. Merge conflict on a file we own → resolve in our favor.
5. Unfixable in one sitting → `git reset --hard ORIG_HEAD`, file an issue,
   ship the previous good tree.

## Project layout

```
zoptia0boringssl/
├── README.md             # upstream BoringSSL README (untouched)
├── LICENSE               # upstream BoringSSL license (untouched)
├── README-zig.md         # this file
├── LICENSE-zig           # MIT license for the build system
├── CLAUDE.md             # internal project spec
├── build.zig             # parses gen/sources.json, builds libcrypto/libssl/libpki
├── build.zig.zon         # package manifest
├── src/root.zig          # minimal Zig wrapper module
├── tests/smoke.zig       # links libssl, calls RAND_bytes
├── scripts/
│   └── sync-upstream.sh  # git fetch upstream && git merge
├── .github/workflows/
│   ├── ci.yml            # build + smoke test on every push
│   └── sync-upstream.yml # weekly upstream sync PR
└── (full BoringSSL source tree at the root: crypto/, ssl/, pki/,
   include/, gen/, third_party/, util/, …)
```

## License

The build system and supporting files in this repository (`build.zig`,
`src/`, `tests/`, `scripts/`, `.github/workflows/{ci,sync-upstream}.yml`)
are MIT-licensed; see [`LICENSE-zig`](LICENSE-zig).

The vendored BoringSSL source retains its own licensing — see
[`LICENSE`](LICENSE).
