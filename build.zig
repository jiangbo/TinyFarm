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
        .strip = optimize != .debug,
        .imports = &.{
            .{ .name = "ecs", .module = migu.module("ecs") },
            .{ .name = "zhu", .module = zhuyu.module("zhu") },
        },
    });
    zhuBuild.installEmsdk(b, zhuyu);

    // 将现有素材原样安装到对应平台的运行目录。
    const assets = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
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
        b.getInstallStep().dependOn(install);
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

    try zhuBuild.fontbm.addStep(b, zhuyu, .{
        .font = "raw-assets/fonts/VonwaonBitmap-16px.ttf",
        .input = "src",
        .size = 16,
        .maxSize = 1024,
        .fixed = true,
    });
    zhuBuild.tiled.addStep(b, zhuyu, .{ .input = "raw-assets" });
    zhuBuild.audio.addStep(b, zhuyu, .{ .rate = 11025, .quality = 0 });
    // 兼容原始素材目录；目标已存在时保留两个文件。
    const oldCrop = "raw-assets/farm-rpg/Farm Crops/Spring/Spring Crops.png";
    const newCrop = "raw-assets/farm-rpg/Farm Crops/Spring Crops.png";
    b.graph.poisonCache();
    const oldPath = try b.root.joinString(b.allocator, oldCrop);
    const newPath = try b.root.joinString(b.allocator, newCrop);
    const cwd = std.Io.Dir.cwd();
    if (cwd.renamePreserve(oldPath, cwd, newPath, b.graph.io)) |_| {
        std.log.info("moved {s} -> {s}", .{ oldCrop, newCrop });
    } else |err| switch (err) {
        error.FileNotFound, error.PathAlreadyExists => {},
        else => return err,
    }
    zhuBuild.atlas.addStep(b, zhuyu, .{
        .input = "raw-assets",
        .include = &.{
            "circle.png",
            "light.png",
            "spot.png",
            "textures/",
            "farm-rpg/",
        },
        .exclude = &.{
            "textures/reserve/",
            "farm-rpg/Farm Animals/Cow/Highlighter Cow/",
            "textures/Tileset/wet.png",
            "textures/UI/farm-rpg-bg.png",
        },
        .fixed = true,
        .mergeFont = true,
    });
    zhuBuild.copy.addStep(b, zhuyu, .{ .items = &.{
        .{
            .src = "raw-assets/textures/UI/farm-rpg-bg.png",
            .dst = "assets/farm-rpg-bg.png",
            .premul = true,
        },
        .{ .src = "raw-assets/cursor.png", .dst = "assets/cursor.png" },
        .{ .src = "raw-assets/icon.ico", .dst = "assets/icon.ico" },
    } });
}
