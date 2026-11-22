const std = @import("std");
const ecs = @import("ecs");

const component = @import("../component.zig");
const Position = component.Position;
const Render = component.render.Render;
const YSort = component.render.YSort;

pub fn update(world: *ecs.World) void {
    var query = world.query(.{ Render, Position, YSort });
    while (query.next()) |row| {
        row.getPtr(Render).depth = row.get(Position).y;
    }
    world.sort(Render, {}, lessThan);
}

fn lessThan(_: void, lhs: Render, rhs: Render) bool {
    if (lhs.layer == rhs.layer) return lhs.depth < rhs.depth;
    return @backingInt(lhs.layer) < @backingInt(rhs.layer);
}

test "渲染排序先比较图层再比较深度" {
    const ground = Render{ .layer = .ground, .depth = 100 };
    const crop = Render{ .layer = .crop, .depth = 0 };
    const actorBack = Render{ .layer = .actor, .depth = 8 };
    const actorFront = Render{ .layer = .actor, .depth = 16 };

    try std.testing.expect(lessThan({}, ground, crop));
    try std.testing.expect(lessThan({}, actorBack, actorFront));
    try std.testing.expect(!lessThan({}, actorFront, actorBack));
}

test "YSort 会把位置 y 写入渲染深度" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    world.add(entity, Position.xy(10, 42));
    world.add(entity, Render{});
    world.add(entity, YSort{});

    update(&world);

    const render = world.get(entity, Render).?;
    try std.testing.expectEqual(42, render.depth);
}
