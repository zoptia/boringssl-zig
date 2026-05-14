// boringssl-zig — pure Zig build for Google's BoringSSL.
//
// This repo is a fork of google/boringssl: upstream files live at the repo
// root, and our additions (build.zig, src/, tests/, scripts/, .github/) sit
// alongside them. Upstream sync is plain `git merge upstream/main`.
//
// We never duplicate BoringSSL's source lists. Instead, we parse the
// upstream-published manifest at gen/sources.json at build time.
//
// Schema (top-level keys we use): "bcm", "crypto", "ssl", "pki".
// Each has: { srcs: [...], hdrs: [...], internal_hdrs: [...],
//            asm: [...], nasm: [...] }.
//
// Asm filename suffixes encode platform: -apple.S, -linux.S, -win.S, -win.asm.
// Each .S file also carries `#if defined(OPENSSL_<arch>) && defined(__<os>__)`
// guards, so it is safe to feed the C preprocessor a file for the wrong arch
// — the result is an empty translation unit. We still filter by OS suffix to
// avoid wasted compile work.

const std = @import("std");

const sources_json = @embedFile("gen/sources.json");

const SourceSet = struct {
    srcs: []const []const u8 = &.{},
    asm_files: []const []const u8 = &.{},
    nasm_files: []const []const u8 = &.{},
};

const Sources = struct {
    arena: std.heap.ArenaAllocator,
    bcm: SourceSet,
    crypto: SourceSet,
    ssl: SourceSet,
    pki: SourceSet,
    test_support: SourceSet,
    crypto_test: SourceSet,
    ssl_test: SourceSet,
    pki_test: SourceSet,
    urandom_test: SourceSet,
};

fn parseSources(gpa: std.mem.Allocator) !Sources {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    const Group = struct {
        srcs: ?[]const []const u8 = null,
        hdrs: ?[]const []const u8 = null,
        internal_hdrs: ?[]const []const u8 = null,
        data: ?[]const []const u8 = null,
        @"asm": ?[]const []const u8 = null,
        nasm: ?[]const []const u8 = null,
    };
    const Schema = struct {
        bcm: ?Group = null,
        crypto: ?Group = null,
        ssl: ?Group = null,
        pki: ?Group = null,
        test_support: ?Group = null,
        crypto_test: ?Group = null,
        ssl_test: ?Group = null,
        pki_test: ?Group = null,
        urandom_test: ?Group = null,
    };

    const parsed = try std.json.parseFromSliceLeaky(
        Schema,
        aalloc,
        sources_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );

    const conv = struct {
        fn pick(g: ?Group) SourceSet {
            const gv = g orelse return .{};
            return .{
                .srcs = gv.srcs orelse &.{},
                .asm_files = gv.@"asm" orelse &.{},
                .nasm_files = gv.nasm orelse &.{},
            };
        }
    };

    return .{
        .arena = arena,
        .bcm = conv.pick(parsed.bcm),
        .crypto = conv.pick(parsed.crypto),
        .ssl = conv.pick(parsed.ssl),
        .pki = conv.pick(parsed.pki),
        .test_support = conv.pick(parsed.test_support),
        .crypto_test = conv.pick(parsed.crypto_test),
        .ssl_test = conv.pick(parsed.ssl_test),
        .pki_test = conv.pick(parsed.pki_test),
        .urandom_test = conv.pick(parsed.urandom_test),
    };
}

/// Returns the OS-suffix of a perlasm-generated .S file: "apple", "linux",
/// "win", or null if the filename doesn't follow the convention (these are
/// hand-written .S files that carry their own arch guards and are always
/// safe to include).
fn asmOsSuffix(path: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[0..i] else base;
    inline for (.{ "apple", "linux", "win" }) |suffix| {
        const tag = "-" ++ suffix;
        if (std.mem.endsWith(u8, stem, tag)) return suffix;
    }
    return null;
}

fn osSuffixFor(target: std.Target) ?[]const u8 {
    return switch (target.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "apple",
        .windows => "win",
        .linux,
        .freebsd,
        .openbsd,
        .netbsd,
        .dragonfly,
        .illumos,
        .haiku,
        .fuchsia,
        => "linux",
        else => null,
    };
}

fn collectAsm(
    b: *std.Build,
    target: std.Target,
    use_nasm: bool,
    sets: []const SourceSet,
) std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    if (use_nasm) {
        for (sets) |s| for (s.nasm_files) |f| list.append(b.allocator, f) catch @panic("OOM");
        return list;
    }
    const want_os = osSuffixFor(target);
    for (sets) |s| for (s.asm_files) |f| {
        if (asmOsSuffix(f)) |suf| {
            if (want_os == null or !std.mem.eql(u8, suf, want_os.?)) continue;
        }
        list.append(b.allocator, f) catch @panic("OOM");
    };
    return list;
}

fn baseCxxFlags(b: *std.Build, target: std.Target, asm_disabled: bool, no_cxx_runtime: bool) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    list.appendSlice(b.allocator, &.{
        "-std=c++17",
        "-fno-strict-aliasing",
        "-fno-common",
        "-fvisibility=hidden",
        "-DBORINGSSL_IMPLEMENTATION",
    }) catch @panic("OOM");
    // BoringSSL upstream CMake applies `-fno-exceptions -fno-rtti` only to the
    // crypto (bcm + libcrypto) target; ssl and pki are built with the default
    // C++ runtime so their classes emit typeinfo. Mirroring that matters when
    // test binaries inherit from ssl/pki classes (e.g. pki_test extending
    // bssl::SimplePathBuilderDelegate) — the derived typeinfo needs the base
    // typeinfo to exist.
    if (no_cxx_runtime) list.appendSlice(b.allocator, &.{
        "-fno-exceptions",
        "-fno-rtti",
    }) catch @panic("OOM");
    if (asm_disabled) list.append(b.allocator, "-DOPENSSL_NO_ASM") catch @panic("OOM");
    switch (target.os.tag) {
        .windows => list.appendSlice(b.allocator, &.{
            // Mirror BoringSSL's Windows defines: keep windows.h slim and
            // prevent symbol collisions with wincrypt.h (X509_NAME, etc.).
            "-DWIN32_LEAN_AND_MEAN",
            "-DNOMINMAX",
            "-D_CRT_SECURE_NO_WARNINGS",
            "-D_HAS_EXCEPTIONS=0",
        }) catch @panic("OOM"),
        .linux => list.append(b.allocator, "-D_XOPEN_SOURCE=700") catch @panic("OOM"),
        else => {},
    }
    // WASM/WASI lacks BSD sockets. The socket-using BIOs are wrapped in
    // `#if !defined(OPENSSL_NO_SOCK)` upstream, so disable them globally
    // for WASM targets to avoid undeclared-identifier errors.
    if (target.cpu.arch.isWasm()) {
        list.appendSlice(b.allocator, &.{
            "-DOPENSSL_NO_SOCK",
            "-DOPENSSL_NO_THREADS_CORRUPT_MEMORY_AND_LEAK_SECRETS_IF_THREADED",
        }) catch @panic("OOM");
    }
    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}

const asm_flags: []const []const u8 = &.{
    "-DBORINGSSL_IMPLEMENTATION",
};

const Libs = struct {
    crypto: *std.Build.Step.Compile,
    ssl: *std.Build.Step.Compile,
    pki: ?*std.Build.Step.Compile,
};

/// Resolve a path that may be absolute (user-supplied prefix) or relative
/// (anything inside the package). `b.path` only accepts relative paths.
fn lazyPath(b: *std.Build, p: []const u8) std.Build.LazyPath {
    if (std.fs.path.isAbsolute(p)) return .{ .cwd_relative = b.dupe(p) };
    return b.path(p);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_asm = b.option(bool, "asm", "Include perlasm-generated assembly (default: true)") orelse true;
    _ = b.option(bool, "fips", "Reserved: enable FIPS module build (not yet supported)") orelse false;
    const prefix = b.option(
        []const u8,
        "prefix",
        "Use prebuilt libcrypto/libssl/libpki from <path>/lib + <path>/include " ++
            "instead of compiling from source. Useful for caching, system installs, " ++
            "or testing a patched build.",
    );
    const sysroot = b.option(
        []const u8,
        "sysroot",
        "SDK sysroot for targets where Zig doesn't bundle libc/headers — iOS " ++
            "(xcrun --sdk iphoneos --show-sdk-path) or Android NDK " ++
            "(<NDK>/toolchains/llvm/prebuilt/<host>/sysroot). " ++
            "Ignored when -Dprefix is used.",
    );

    var sources = parseSources(b.allocator) catch |err| {
        std.debug.panic("failed to parse gen/sources.json: {t}", .{err});
    };
    _ = &sources;

    const libs = if (prefix) |p|
        buildFromPrefix(b, target, optimize, p)
    else
        buildFromSource(b, target, optimize, enable_asm, sysroot, &sources);

    // -------- public Zig wrapper module --------
    //
    // BoringSSL's headers cannot be reliably translated by `zig translate-c`
    // (the macro-heavy DEFINE_STACK_OF defeats the C importer). The wrapper
    // therefore exposes only hand-written extern declarations — see
    // src/root.zig — and consumers add more as they need them.
    const mod = b.addModule("boringssl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.linkLibrary(libs.ssl);

    // -------- smoke test --------
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("tests/smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_mod.addImport("boringssl", mod);
    const smoke = b.addExecutable(.{
        .name = "smoke",
        .root_module = smoke_mod,
    });

    const run_smoke = b.addRunArtifact(smoke);
    const test_step = b.step("test", "Build, install, and run the smoke test");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_smoke.step);

    // -------- BoringSSL upstream C++ test suite --------
    //
    // Only available in source mode (test_support / *_test sources live in the
    // upstream tree, not in any prefix install). Builds gtest, test_support,
    // then four test binaries (crypto/ssl/pki/urandom) linked against our
    // freshly-built .a's. Run them all via `zig build test-all`.
    if (prefix == null) {
        addUpstreamTests(b, target, optimize, enable_asm, &sources, libs);
    }
}

fn buildFromSource(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enable_asm: bool,
    sysroot: ?[]const u8,
    sources: *Sources,
) Libs {
    const t = target.result;
    // Helper: when -Dsysroot is set, point system include + lib search at it.
    // Used for iOS (Xcode SDK) and Android (NDK sysroot) where Zig has no
    // bundled libc/libc++ for the target.
    const applySysroot = struct {
        fn apply(mod: *std.Build.Module, sr: ?[]const u8, bb: *std.Build) void {
            const s = sr orelse return;
            // Order matters — c++/v1 first so libc++ headers shadow libc's.
            mod.addSystemIncludePath(.{ .cwd_relative = bb.pathJoin(&.{ s, "usr/include/c++/v1" }) });
            mod.addSystemIncludePath(.{ .cwd_relative = bb.pathJoin(&.{ s, "usr/include" }) });
            mod.addLibraryPath(.{ .cwd_relative = bb.pathJoin(&.{ s, "usr/lib" }) });
        }
    }.apply;
    const is_win_x86_family = t.os.tag == .windows and (t.cpu.arch == .x86 or t.cpu.arch == .x86_64);
    const use_nasm = enable_asm and is_win_x86_family;
    // crypto (incl. bcm) is built with -fno-rtti -fno-exceptions to match
    // upstream. ssl and pki use a separate cflag set without those, so their
    // typeinfo gets emitted (test binaries depend on this).
    const crypto_cflags = baseCxxFlags(b, t, !enable_asm, true);
    const ssl_pki_cflags = baseCxxFlags(b, t, !enable_asm, false);

    // -------- libcrypto --------
    const crypto_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    applySysroot(crypto_mod, sysroot, b);
    crypto_mod.addIncludePath(b.path("include"));
    crypto_mod.addCSourceFiles(.{
        .files = sources.crypto.srcs,
        .flags = crypto_cflags,
        .language = .cpp,
    });
    crypto_mod.addCSourceFiles(.{
        .files = sources.bcm.srcs,
        .flags = crypto_cflags,
        .language = .cpp,
    });

    if (enable_asm) {
        var asm_list = collectAsm(b, t, use_nasm, &.{ sources.crypto, sources.bcm });
        defer asm_list.deinit(b.allocator);
        if (asm_list.items.len > 0) {
            if (use_nasm) {
                addNasmObjects(b, crypto_mod, target, asm_list.items);
            } else {
                crypto_mod.addCSourceFiles(.{
                    .files = asm_list.items,
                    .flags = asm_flags,
                    .language = .assembly_with_preprocessor,
                });
            }
        }
    }

    if (t.os.tag == .windows) {
        crypto_mod.linkSystemLibrary("ws2_32", .{});
        crypto_mod.linkSystemLibrary("advapi32", .{});
    }

    const crypto_lib = b.addLibrary(.{
        .name = "crypto",
        .linkage = .static,
        .root_module = crypto_mod,
    });
    crypto_lib.installHeadersDirectory(
        b.path("include"),
        "",
        .{ .include_extensions = &.{".h"} },
    );
    b.installArtifact(crypto_lib);

    // -------- libssl --------
    const ssl_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    applySysroot(ssl_mod, sysroot, b);
    ssl_mod.addIncludePath(b.path("include"));
    ssl_mod.addCSourceFiles(.{
        .files = sources.ssl.srcs,
        .flags = ssl_pki_cflags,
        .language = .cpp,
    });
    ssl_mod.linkLibrary(crypto_lib);
    const ssl_lib = b.addLibrary(.{
        .name = "ssl",
        .linkage = .static,
        .root_module = ssl_mod,
    });
    b.installArtifact(ssl_lib);

    // -------- libpki (optional, present in current upstream) --------
    var pki_lib_opt: ?*std.Build.Step.Compile = null;
    if (sources.pki.srcs.len > 0) {
        const pki_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        applySysroot(pki_mod, sysroot, b);
        pki_mod.addIncludePath(b.path("include"));
        var pki_flags: std.ArrayList([]const u8) = .empty;
        pki_flags.appendSlice(b.allocator, ssl_pki_cflags) catch @panic("OOM");
        if (t.os.tag.isDarwin()) pki_flags.append(b.allocator, "-fno-aligned-new") catch @panic("OOM");
        pki_mod.addCSourceFiles(.{
            .files = sources.pki.srcs,
            .flags = pki_flags.items,
            .language = .cpp,
        });
        pki_mod.linkLibrary(crypto_lib);
        const pki_lib = b.addLibrary(.{
            .name = "pki",
            .linkage = .static,
            .root_module = pki_mod,
        });
        b.installArtifact(pki_lib);
        pki_lib_opt = pki_lib;
    }

    return .{ .crypto = crypto_lib, .ssl = ssl_lib, .pki = pki_lib_opt };
}

/// Build "libraries" that just re-export prebuilt archives from a user-supplied
/// install prefix. Layout expected at `<prefix>/`:
///   lib/lib{crypto,ssl,pki}.a       (Unix / MinGW)
///   lib/{crypto,ssl,pki}.lib        (MSVC)
///   include/openssl/*.h
fn buildFromPrefix(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    prefix: []const u8,
) Libs {
    const t = target.result;
    const inc = lazyPath(b, b.pathJoin(&.{ prefix, "include" }));

    const crypto = wrapPrebuiltLib(b, "crypto", target, optimize, prefix, inc);
    if (t.os.tag == .windows) {
        crypto.root_module.linkSystemLibrary("ws2_32", .{});
        crypto.root_module.linkSystemLibrary("advapi32", .{});
    }
    crypto.installHeadersDirectory(inc, "", .{ .include_extensions = &.{".h"} });
    b.installArtifact(crypto);

    const ssl = wrapPrebuiltLib(b, "ssl", target, optimize, prefix, inc);
    ssl.root_module.linkLibrary(crypto);
    b.installArtifact(ssl);

    const pki = wrapPrebuiltLib(b, "pki", target, optimize, prefix, inc);
    pki.root_module.linkLibrary(crypto);
    b.installArtifact(pki);

    return .{ .crypto = crypto, .ssl = ssl, .pki = pki };
}

fn wrapPrebuiltLib(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    prefix: []const u8,
    include_path: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const t = target.result;
    const archive_basename = if (t.os.tag == .windows and t.abi == .msvc)
        b.fmt("{s}.lib", .{name})
    else
        b.fmt("lib{s}.a", .{name});
    const archive = lazyPath(b, b.pathJoin(&.{ prefix, "lib", archive_basename }));

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addObjectFile(archive);
    mod.addIncludePath(include_path);
    return b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = mod,
    });
}

fn addNasmObjects(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    files: []const []const u8,
) void {
    const nasm_format = switch (target.result.cpu.arch) {
        .x86 => "win32",
        .x86_64 => "win64",
        else => @panic("addNasmObjects: unsupported arch"),
    };
    for (files) |rel| {
        const src = b.path(rel);
        const stem = blk: {
            const base = std.fs.path.basename(rel);
            const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
            break :blk base[0..dot];
        };
        const obj_name = b.fmt("{s}.obj", .{stem});
        const run = b.addSystemCommand(&.{ "nasm", "-f", nasm_format });
        run.addArg("-o");
        const obj = run.addOutputFileArg(obj_name);
        run.addFileArg(src);
        mod.addObjectFile(obj);
    }
}

// =============================================================================
// Upstream BoringSSL C++ test suite
// =============================================================================
//
// gtest is vendored under third_party/googletest/. test_support, crypto_test,
// ssl_test, pki_test, urandom_test sources come from sources.json.
//
// The test code (unlike libcrypto/libssl/libpki) needs RTTI and exceptions
// because gtest does. We therefore use a separate cflag set without the
// -fno-rtti / -fno-exceptions BoringSSL builds itself with.

/// sources.json may list both .cc (C++) and .c (C) sources for a test group,
/// plus the occasional .c.inc / .h that is purely an #include fragment.
/// Split them so each compiles with the right language flag.
fn splitSourcesByLang(b: *std.Build, srcs: []const []const u8) struct {
    cpp: []const []const u8,
    c: []const []const u8,
} {
    var cpp: std.ArrayList([]const u8) = .empty;
    var c: std.ArrayList([]const u8) = .empty;
    for (srcs) |s| {
        if (std.mem.endsWith(u8, s, ".cc")) {
            cpp.append(b.allocator, s) catch @panic("OOM");
        } else if (std.mem.endsWith(u8, s, ".c")) {
            c.append(b.allocator, s) catch @panic("OOM");
        }
        // .c.inc / .h / etc. are include fragments; let them ride along
        // implicitly via the .cc files that #include them.
    }
    return .{
        .cpp = cpp.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .c = c.toOwnedSlice(b.allocator) catch @panic("OOM"),
    };
}

fn baseTestCFlags(b: *std.Build, target: std.Target) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    list.appendSlice(b.allocator, &.{
        "-std=c11",
        "-fno-strict-aliasing",
        "-fno-common",
    }) catch @panic("OOM");
    switch (target.os.tag) {
        .windows => list.appendSlice(b.allocator, &.{
            "-DWIN32_LEAN_AND_MEAN",
            "-DNOMINMAX",
            "-D_CRT_SECURE_NO_WARNINGS",
        }) catch @panic("OOM"),
        .linux => list.append(b.allocator, "-D_XOPEN_SOURCE=700") catch @panic("OOM"),
        else => {},
    }
    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn baseTestCxxFlags(b: *std.Build, target: std.Target) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    list.appendSlice(b.allocator, &.{
        "-std=c++17",
        "-fno-strict-aliasing",
        "-fno-common",
    }) catch @panic("OOM");
    switch (target.os.tag) {
        .windows => list.appendSlice(b.allocator, &.{
            "-DWIN32_LEAN_AND_MEAN",
            "-DNOMINMAX",
            "-D_CRT_SECURE_NO_WARNINGS",
        }) catch @panic("OOM"),
        .linux => list.append(b.allocator, "-D_XOPEN_SOURCE=700") catch @panic("OOM"),
        else => {},
    }
    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn addUpstreamTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enable_asm: bool,
    sources: *Sources,
    libs: Libs,
) void {
    const t = target.result;
    const test_cxx_flags = baseTestCxxFlags(b, t);
    const test_c_flags = baseTestCFlags(b, t);

    // gtest static lib (vendored under third_party/googletest/).
    const gtest_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    inline for (.{
        "third_party/googletest/googlemock/include",
        "third_party/googletest/googletest/include",
        "third_party/googletest/googlemock",
        "third_party/googletest/googletest",
    }) |p| gtest_mod.addIncludePath(b.path(p));
    gtest_mod.addCSourceFiles(.{
        .files = &.{
            "third_party/googletest/googlemock/src/gmock-all.cc",
            "third_party/googletest/googletest/src/gtest-all.cc",
        },
        .flags = test_cxx_flags,
        .language = .cpp,
    });
    const gtest_lib = b.addLibrary(.{
        .name = "boringssl_gtest",
        .linkage = .static,
        .root_module = gtest_mod,
    });

    // test_support static lib.
    const ts_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    ts_mod.addIncludePath(b.path("include"));
    ts_mod.addIncludePath(b.path("third_party/googletest/googletest/include"));
    ts_mod.addIncludePath(b.path("third_party/googletest/googlemock/include"));
    {
        const split = splitSourcesByLang(b, sources.test_support.srcs);
        ts_mod.addCSourceFiles(.{ .files = split.cpp, .flags = test_cxx_flags, .language = .cpp });
        if (split.c.len > 0) {
            ts_mod.addCSourceFiles(.{ .files = split.c, .flags = test_c_flags, .language = .c });
        }
    }
    if (enable_asm) {
        const is_win_x86_family = t.os.tag == .windows and (t.cpu.arch == .x86 or t.cpu.arch == .x86_64);
        const use_nasm = is_win_x86_family;
        var asm_list = collectAsm(b, t, use_nasm, &.{sources.test_support});
        defer asm_list.deinit(b.allocator);
        if (asm_list.items.len > 0) {
            if (use_nasm) {
                addNasmObjects(b, ts_mod, target, asm_list.items);
            } else {
                ts_mod.addCSourceFiles(.{
                    .files = asm_list.items,
                    .flags = asm_flags,
                    .language = .assembly_with_preprocessor,
                });
            }
        }
    }
    ts_mod.linkLibrary(gtest_lib);
    ts_mod.linkLibrary(libs.crypto);
    const ts_lib = b.addLibrary(.{
        .name = "boringssl_test_support",
        .linkage = .static,
        .root_module = ts_mod,
    });

    const test_all = b.step("test-all", "Build and run BoringSSL's C++ test suite linked to our libs");

    addOneTest(b, target, optimize, "crypto_test", sources.crypto_test.srcs,
        test_cxx_flags, test_c_flags, gtest_lib, ts_lib, &.{ libs.ssl, libs.crypto }, test_all);
    addOneTest(b, target, optimize, "ssl_test", sources.ssl_test.srcs,
        test_cxx_flags, test_c_flags, gtest_lib, ts_lib, &.{ libs.ssl, libs.crypto }, test_all);
    if (libs.pki) |pki| {
        var deps = [_]*std.Build.Step.Compile{ pki, libs.crypto };
        addOneTest(b, target, optimize, "pki_test", sources.pki_test.srcs,
            test_cxx_flags, test_c_flags, gtest_lib, ts_lib, deps[0..], test_all);
    }
    if (t.os.tag == .linux) {
        addOneTest(b, target, optimize, "urandom_test", sources.urandom_test.srcs,
            test_cxx_flags, test_c_flags, gtest_lib, ts_lib, &.{libs.crypto}, test_all);
    }
}

fn addOneTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    srcs: []const []const u8,
    test_cxx_flags: []const []const u8,
    test_c_flags: []const []const u8,
    gtest_lib: *std.Build.Step.Compile,
    ts_lib: *std.Build.Step.Compile,
    extra_libs: []const *std.Build.Step.Compile,
    test_all: *std.Build.Step,
) void {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("third_party/googletest/googletest/include"));
    mod.addIncludePath(b.path("third_party/googletest/googlemock/include"));

    const split = splitSourcesByLang(b, srcs);
    mod.addCSourceFiles(.{ .files = split.cpp, .flags = test_cxx_flags, .language = .cpp });
    if (split.c.len > 0) {
        mod.addCSourceFiles(.{ .files = split.c, .flags = test_c_flags, .language = .c });
    }

    mod.linkLibrary(ts_lib);
    mod.linkLibrary(gtest_lib);
    for (extra_libs) |l| mod.linkLibrary(l);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
    const run = b.addRunArtifact(exe);
    // Test data files (crypto/blake2/*_tests.txt, pki/testdata/*) are
    // referenced relative to the BoringSSL root; run with cwd = repo root.
    run.setCwd(b.path("."));
    test_all.dependOn(&run.step);
}
