const std = @import("std");
const config = @import("./libs/tigerbeetle/src/config.zig");
const builtin = @import("builtin");
const CrossTarget = std.zig.CrossTarget;
const Mode = std.builtin.Mode;
const VoprStateMachine = enum { testing, accounting };
const VoprLog = enum { short, full };
fn resolve_target(b: *std.Build, target_requested: ?[]const u8) !std.Build.ResolvedTarget {
    const target_host = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
    const target = target_requested orelse target_host;
    const triples = .{
        "aarch64-linux",
        "aarch64-macos",
        "x86_64-linux",
        "x86_64-macos",
        "x86_64-windows",
    };
    const cpus = .{
        "baseline+aes+neon",
        "baseline+aes+neon",
        "x86_64_v3+aes",
        "x86_64_v3+aes",
        "x86_64_v3+aes",
    };

    const arch_os, const cpu = inline for (triples, cpus) |triple, cpu| {
        if (std.mem.eql(u8, target, triple)) break .{ triple, cpu };
    } else {
        std.log.err("unsupported target: '{s}'", .{target});
        return error.UnsupportedTarget;
    };
    const query = try CrossTarget.parse(.{
        .arch_os_abi = arch_os,
        .cpu_features = cpu,
    });
    return b.resolveTargetQuery(query);
}

const zig_version = std.SemanticVersion{
    .major = 0,
    .minor = 13,
    .patch = 0,
};

comptime {
    // Compare versions while allowing different pre/patch metadata.
    const zig_version_eq = zig_version.major == builtin.zig_version.major and
        zig_version.minor == builtin.zig_version.minor and
        zig_version.patch == builtin.zig_version.patch;
    if (!zig_version_eq) {
        @compileError(std.fmt.comptimePrint(
            "unsupported zig version: expected {}, found {}",
            .{ zig_version, builtin.zig_version },
        ));
    }
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const build_options = .{
        .target = b.option([]const u8, "target", "The CPU architecture and OS to build for"),
        .multiversion = b.option(
            []const u8,
            "multiversion",
            "Past version to include for upgrades (\"latest\" or \"x.y.z\")",
        ),
        .multiversion_file = b.option(
            []const u8,
            "multiversion-file",
            "Past version to include for upgrades (local binary file)",
        ),
        .config_verify = b.option(bool, "config_verify", "Enable extra assertions.") orelse true,
        .config_aof_recovery = b.option(
            bool,
            "config-aof-recovery",
            "Enable AOF Recovery mode.",
        ) orelse false,
        .config_release = b.option([]const u8, "config-release", "Release triple."),
        .config_release_client_min = b.option(
            []const u8,
            "config-release-client-min",
            "Minimum client release triple.",
        ),
        // We run extra checks in "CI-mode" build.
        .ci = b.graph.env_map.get("CI") != null,
        .emit_llvm_ir = b.option(bool, "emit-llvm-ir", "Emit LLVM IR (.ll file)") orelse false,
        // The "tigerbeetle version" command includes the build-time commit hash.
        .git_commit = b.option(
            []const u8,
            "git-commit",
            "The git commit revision of the source code.",
        ) orelse "9721f287401a899aa1e46bae78f437c48b521c73",
        .hash_log_mode = b.option(
            config.HashLogMode,
            "hash-log-mode",
            "Log hashes (used for debugging non-deterministic executions).",
        ) orelse .none,
        .vopr_state_machine = b.option(
            VoprStateMachine,
            "vopr-state-machine",
            "State machine.",
        ) orelse .accounting,
        .vopr_log = b.option(
            VoprLog,
            "vopr-log",
            "Log only state transitions (short) or everything (full).",
        ) orelse .short,
        .llvm_objcopy = b.option(
            []const u8,
            "llvm-objcopy",
            "Use this llvm-objcopy instead of downloading one",
        ),
        .print_exe = b.option(
            bool,
            "print-exe",
            "Build tasks print the path of the executable",
        ) orelse false,
    };
    const target = try resolve_target(b, build_options.target);

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mesh",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const xev = b.dependency("zzz", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zzz", xev.module("zzz"));

    const module = b.addModule("zli", .{
        .root_source_file = .{ .cwd_relative = "./libs/zli/src/zli.zig" },
    });
    exe.root_module.addImport("zli", module);

    // const vsr = b.addModule("vsr", .{
    //     .root_source_file = b.path("./libs/tigerbeetle/src/vsr.zig"),
    // });
    // const vsr_options = b.addModule("vsr_options", .{
    //     .root_source_file = b.path("./libs/tigerbeetle/src/vsr.zig"),
    // });
    //
    // exe.root_module.addImport("vsr", vsr);
    const vsr_options, const vsr_module = build_vsr_module(b, .{
        .target = target,
        .git_commit = build_options.git_commit[0..40].*,
        .config_verify = true,
        .config_release = "0.16.27",
        .config_release_client_min = "0.0.1",
        .config_aof_recovery = build_options.config_aof_recovery,
        .hash_log_mode = build_options.hash_log_mode,
    });

    const tb = b.addModule("tb_client", .{
        .root_source_file = .{ .src_path = .{ .sub_path = "./libs/tigerbeetle/src/tigerbeetle/libtb_client.zig", .owner = b } },
    });
    tb.addImport("vsr", vsr_module);
    tb.addOptions("vsr_options", vsr_options);

    exe.root_module.addImport("tb", tb);
    exe.root_module.addImport("vsr", vsr_module);
    exe.root_module.addOptions("vsr_options", vsr_options);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
fn build_vsr_module(b: *std.Build, options: struct {
    target: std.Build.ResolvedTarget,
    git_commit: [40]u8,
    config_verify: bool,
    config_release: ?[]const u8,
    config_release_client_min: ?[]const u8,
    config_aof_recovery: bool,
    hash_log_mode: config.HashLogMode,
}) struct { *std.Build.Step.Options, *std.Build.Module } {
    // Ideally, we would return _just_ the module here, and keep options an implementation detail.
    // However, currently Zig makes it awkward to provide multiple entry points for a module:
    // https://ziggit.dev/t/suggested-project-layout-for-multiple-entry-point-for-zig-0-12/4219
    //
    // For this reason, we have to return options as well, so that other entry points can
    // essentially re-create identical module.
    const vsr_options = b.addOptions();
    vsr_options.addOption(?[40]u8, "git_commit", options.git_commit[0..40].*);
    vsr_options.addOption(bool, "config_verify", options.config_verify);
    vsr_options.addOption(?[]const u8, "release", "0.16.27");
    vsr_options.addOption(
        ?[]const u8,
        "release_client_min",
        "0.0.1",
    );
    vsr_options.addOption(bool, "config_aof_recovery", options.config_aof_recovery);
    vsr_options.addOption(config.HashLogMode, "hash_log_mode", options.hash_log_mode);

    const vsr_module = b.createModule(.{
        .root_source_file = b.path("./libs/tigerbeetle/src/vsr.zig"),
    });
    vsr_module.addOptions("vsr_options", vsr_options);

    return .{ vsr_options, vsr_module };
}
