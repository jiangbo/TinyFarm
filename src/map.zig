const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("component.zig");
const factory = @import("factory.zig");
const loader = @import("map/loader.zig");
const storage = @import("storage.zig");
const Map = @import("resource/Map.zig");

const World = ecs.World;
const Id = component.map.Id;

pub fn enter(gpa: std.mem.Allocator, world: *World, id: Id) void {
    var current = loader.load(gpa, world, id);
    storage.applyMap(gpa, world, &current);
    world.addResource(current);
    zhu.camera.bound = current.grid.size();

    // 原始地图没有住宅室外与城镇的连接，由游戏补充。
    const trigger: component.map.Trigger = switch (id) {
        .home_exterior => .{
            .rect = .init(.xy(552, 227), .xy(7, 25)),
            .selfId = 2,
            .targetId = 2,
            .targetMap = .town,
            .startOffset = .left,
        },
        .town => .{
            .rect = .init(.xy(1, 227), .xy(7, 25)),
            .selfId = 2,
            .targetId = 2,
            .targetMap = .home_exterior,
            .startOffset = .right,
        },
        else => return,
    };
    _ = factory.spawnMapTrigger(world, trigger);
}

pub fn exit(gpa: std.mem.Allocator, world: *World) void {
    storage.captureMap(gpa, world);
    unload(gpa, world);
}

pub fn unload(gpa: std.mem.Allocator, world: *World) void {
    const current = world.getResourcePtr(Map) orelse return;
    current.deinit(gpa);
    world.removeResource(Map);
}
