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

fn baseCxxFlags(b: *std.Build, target: std.Target, asm_disabled: bool) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    list.appendSlice(b.allocator, &.{
        "-std=c++17",
        "-fno-strict-aliasing",
        "-fno-common",
        "-fvisibility=hidden",
        "-DBORINGSSL_IMPLEMENTATION",
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

    const libs = if (prefix) |p|
        buildFromPrefix(b, target, optimize, p)
    else
        buildFromSource(b, target, optimize, enable_asm);

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
}

fn buildFromSource(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    enable_asm: bool,
) Libs {
    var sources = parseSources(b.allocator) catch |err| {
        std.debug.panic("failed to parse gen/sources.json: {t}", .{err});
    };
    _ = &sources;

    const t = target.result;
    const is_win_x86_family = t.os.tag == .windows and (t.cpu.arch == .x86 or t.cpu.arch == .x86_64);
    const use_nasm = enable_asm and is_win_x86_family;
    const cflags = baseCxxFlags(b, t, !enable_asm);

    // -------- libcrypto --------
    const crypto_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    crypto_mod.addIncludePath(b.path("include"));
    crypto_mod.addCSourceFiles(.{
        .files = sources.crypto.srcs,
        .flags = cflags,
        .language = .cpp,
    });
    crypto_mod.addCSourceFiles(.{
        .files = sources.bcm.srcs,
        .flags = cflags,
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
    ssl_mod.addIncludePath(b.path("include"));
    ssl_mod.addCSourceFiles(.{
        .files = sources.ssl.srcs,
        .flags = cflags,
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
        pki_mod.addIncludePath(b.path("include"));
        var pki_flags: std.ArrayList([]const u8) = .empty;
        pki_flags.appendSlice(b.allocator, cflags) catch @panic("OOM");
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
