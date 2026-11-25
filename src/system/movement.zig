const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("../component.zig");
const map = @import("../map.zig");

const spatial = zhu.extend.spatial;
const Position = component.Position;
const Player = component.actor.Player;
const Velocity = component.motion.Velocity;
const Shape = component.motion.Shape;
const Blocking = component.motion.Blocking;
const World = ecs.World;
const Entity = ecs.Entity;

pub fn update(world: *const World, delta: f32) void {
    move(world, map.collision(), delta);
    followPlayer(world, delta);
}

fn move(world: *const World, collision: *const spatial.Static, delta: f32) void {
    var query = world.query(.{ Position, Velocity });
    while (query.next()) |row| {
        const velocity = row.get(Velocity);
        if (velocity.value.approxEqual(.zero)) continue;

        const pos = row.getPtr(Position);
        const offset = velocity.value.scale(delta);
        pos.* = pos.add(slide(world, collision, row.entity, offset));
    }
}

// 合并静态碰撞与动态实体的碰撞，计算滑墙后的实际位移。
fn slide(
    world: *const World,
    collision: *const spatial.Static,
    entity: Entity,
    delta: zhu.Vector2,
) zhu.Vector2 {
    const position = world.get(entity, Position).?;
    const body = world.get(entity, Shape).?.move(position);
    var s = spatial.Slide.init(body, delta);
    while (s.next()) |step| {
        var best = collision.sweep(step.body, step.move);

        var query = world.query(.{ Position, Shape, Blocking });
        while (query.next()) |row| {
            if (row.entity == entity) continue;
            const other = row.get(Shape).move(row.get(Position));
            if (step.body.sweep(other, step.move)) |hit| {
                spatial.Contact.record(&best, hit);
            }
        }
        s.advance(best);
    }
    return s.moved;
}

fn followPlayer(world: *const World, delta: f32) void {
    const entity = world.getIdentity(Player) orelse return;
    const position = world.get(entity, Position).?;

    const speed: f32 = 9;
    zhu.camera.smoothFollow(position, speed, delta);
}

test "有碰撞形状的实体只有带 Blocking 才阻挡移动" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const shape: Shape = .{ .rect = .init(.zero, .xy(10, 10)) };
    const mover = world.createEntity();
    world.add(mover, Position.zero);
    world.add(mover, Velocity{ .value = .xy(20, 10) });
    world.add(mover, shape);
    world.add(mover, Blocking{});

    const obstacle = world.createEntity();
    world.add(obstacle, Position.xy(10, 0));
    world.add(obstacle, shape);

    move(&world, &.{}, 0.5);
    try std.testing.expectEqual(Position.xy(10, 5), world.get(mover, Position).?);

    world.getPtr(mover, Position).?.* = .zero;
    world.add(obstacle, Blocking{});
    move(&world, &.{}, 0.5);
    try std.testing.expectEqual(Position.xy(0, 5), world.get(mover, Position).?);
}
