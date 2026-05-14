# boringssl-zig

A pure-Zig build of [Google's BoringSSL](https://github.com/google/boringssl).

This repository is a **fork** of `google/boringssl`: upstream files live at
the repo root unchanged, and our additions (`build.zig`, `src/`, `tests/`,
`scripts/`, `.github/workflows/ci.yml`, `.github/workflows/sync-upstream.yml`)
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
zig fetch --save=boringssl git+https://github.com/zoptia/boringssl-zig#v0.20260513.0
```

Then in your `build.zig`:

```zig
const boringssl = b.dependency("boringssl", .{
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{
    .name = "myapp",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }),
});
exe.linkLibrary(boringssl.artifact("ssl"));     // pulls in libcrypto too
// Headers under <openssl/...> are now visible — no extra addIncludePath needed.
```

If you want only `libcrypto`, link `boringssl.artifact("crypto")` instead. A
third artifact, `pki`, is also available.

A minimal Zig wrapper module is exposed under the name `boringssl`:

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
| `-Dfips=…` | (reserved) | FIPS module is not supported yet |

### Windows note

For `x86_64-windows`, BoringSSL's perlasm output is in NASM syntax and Zig
does not bundle NASM. Build with `-Dasm=false` for a portable build (slower
crypto), or install NASM in `PATH` and the build will shell out to it. ARM
Windows uses GAS-format `.S` files and works without external tools.

## Build requirements

- **Zig 0.16+** (development tracks Zig nightly `0.17.0-dev.298+ad1b746e2`
  or newer; the `0.16.0` stable release also works).
- **Nothing else.** Go is *only* needed if you regenerate the files under
  `gen/`, which boringssl-zig never does at build time (they ship
  pre-generated upstream).

## Versioning

Tags follow `v0.YYYYMMDD.0`, where `YYYYMMDD` is the date of the upstream
BoringSSL commit that was merged. The `.0` patch component bumps for
build-system-only fixes between syncs (e.g., `v0.20260513.1`).

## Maintainer guide

### Pull the latest upstream

```sh
./scripts/sync-upstream.sh
zig build test
git push
```

The sync script is idempotent: it adds an `upstream` remote on first run if
not present, then `git fetch upstream && git merge upstream/main`. Conflicts
are uncommon — most file paths owned by us (`build.zig`, `src/…`, `tests/…`,
`scripts/…`, `LICENSE-zig`, `README-zig.md`, `CLAUDE.md`,
`.github/workflows/ci.yml`, `.github/workflows/sync-upstream.yml`) have
names upstream does not use.

### Tag a release

```sh
git tag v0.$(date +%Y%m%d).0
git push --tags
```

A weekly GitHub Action (`.github/workflows/sync-upstream.yml`) runs the
sync script and opens a PR. CI on the PR verifies the new tree still
compiles before merge.

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
boringssl-zig/
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
