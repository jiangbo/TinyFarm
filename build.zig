const std = @import("std");
const zhuBuild = @import("zhuyu");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web = target.result.os.tag == .emscripten;
    const zhuyu = b.dependency("zhuyu", .{
        .target = target,
        .optimize = optimize,
    });
    const migu = b.dependency("migu", .{
        .target = target,
        .optimize = optimize,
    });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs", .module = migu.module("ecs") },
            .{ .name = "zhu", .module = zhuyu.module("zhu") },
        },
    });
    zhuBuild.installEmsdk(b, zhuyu);

    // 将现有素材原样安装到对应平台的运行目录。
    const assets = b.addInstallDirectory(.{
        .source_dir = b.path("raw-assets"),
        .install_dir = if (web) .prefix else .bin,
        .install_subdir = if (web) "web/assets" else "assets",
    });
    b.getInstallStep().dependOn(&assets.step);

    if (web) {
        const install = try zhuBuild.buildWeb(b, zhuyu, .{
            .name = "demo",
            .root_module = mod,
            .shell = b.path("index.html"),
        });
        b.getInstallStep().dependOn(&install.step);
    } else {
        const exe = b.addExecutable(.{ .name = "demo", .root_module = mod });
        zhuBuild.setLibC(zhuyu, exe);
        if (target.result.os.tag == .windows and optimize != .debug)
            exe.subsystem = .windows;
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        run.setCwd(.{ .relative = .{ .base = .install_bin } });
        run.addPassthruArgs();
        b.step("run", "Run the app").dependOn(&run.step);
    }

    const tests = b.addTest(.{ .name = "tests", .root_module = mod });
    zhuBuild.setLibC(zhuyu, tests);
    const runTests = b.addRunArtifact(tests);
    b.step("test", "Run farm tests").dependOn(&runTests.step);
}
