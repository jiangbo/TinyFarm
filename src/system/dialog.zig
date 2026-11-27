const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("../component.zig");

const World = ecs.World;
const Entity = ecs.Entity;
const Position = component.Position;
const Player = component.actor.Player;
const Actor = component.actor.Actor;
const Dialog = component.actor.Dialog;
const Interact = component.actor.Interact;
const Velocity = component.motion.Velocity;

pub fn update(world: *World) void {
    if (world.getIdentity(Dialog)) |target| {
        if (!inRange(world, target)) return close(world, target);
        if (zhu.action.pressed(.interact)) advanceDialog(world, target);
        return;
    }

    const target = world.getIdentity(Interact) orelse return;
    startDialog(world, target);
}

fn inRange(world: *World, target: Entity) bool {
    const player = world.getIdentity(Player).?;
    const playerPos = world.get(player, Position).?;
    const targetPos = world.get(target, Position).?;
    return playerPos.sub(targetPos).length() <= Dialog.closeDist;
}

fn startDialog(world: *World, target: Entity) void {
    const dialog = world.getPtr(target, Dialog) orelse return;
    if (dialog.lines.len == 0) return;

    dialog.index = 0;
    facePlayer(world, target);
    world.setIdentity(target, Dialog);
}

fn facePlayer(world: *const World, target: Entity) void {
    const player = world.getIdentity(Player).?;
    const playerPos = world.get(player, Position).?;
    const targetPos = world.get(target, Position).?;

    // 对话开始时 NPC 停下，并面向玩家。
    if (world.getPtr(target, Velocity)) |velocity| {
        velocity.value = .zero;
    }
    const actor = world.getPtr(target, Actor).?;
    actor.action = .idle;

    const direction = playerPos.sub(targetPos);
    if (!direction.approxEqual(.zero)) {
        actor.facing = facingFromDirection(direction);
    }
}

fn facingFromDirection(direction: zhu.Vector2) component.actor.Facing {
    if (@abs(direction.x) > @abs(direction.y)) {
        return if (direction.x < 0) .left else .right;
    }
    return if (direction.y < 0) .up else .down;
}

fn advanceDialog(world: *World, target: Entity) void {
    const dialog = world.getPtr(target, Dialog).?;

    dialog.index += 1;
    if (dialog.index >= dialog.lines.len) close(world, target);
}

fn close(world: *World, target: Entity) void {
    world.getPtr(target, Dialog).?.index = 0;
    world.add(target, Interact.Cooldown{ .timer = .init(0.35) });
    world.removeIdentity(Dialog);
}

fn addTestPlayer(world: *World, position: Position) Entity {
    const player = world.createIdentity(Player);
    world.add(player, position);
    return player;
}

fn addTestNpc(world: *World, position: Position) Entity {
    const npc = world.createEntity();
    world.add(npc, position);
    world.add(npc, Actor{});
    world.add(npc, Velocity{ .value = .xy(1, 0) });
    world.add(npc, Dialog{ .lines = &.{ "你好", "再见" } });
    return npc;
}

test "dialog 消费交互标记并开始对话" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    _ = addTestPlayer(&world, .xy(0, 0));
    const npc = addTestNpc(&world, .xy(0, 10));
    world.setIdentity(npc, Interact);

    update(&world);

    try std.testing.expectEqual(npc, world.getIdentity(Dialog).?);
    try std.testing.expectEqual(npc, world.getIdentity(Interact).?);
    try std.testing.expect(world.get(npc, Velocity).?.value.approxEqual(.zero));
    try std.testing.expectEqual(.up, world.get(npc, Actor).?.facing);
}

test "dialog 连按 F 可以读完对话，结束后才进入冷却" {
    zhu.window.resetInput();
    defer zhu.window.resetInput();

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    _ = addTestPlayer(&world, .xy(0, 0));
    const npc = addTestNpc(&world, .xy(0, 10));
    world.setIdentity(npc, Interact);
    update(&world);
    world.removeIdentity(Interact);

    zhu.key.set(.F, true);
    update(&world);
    try std.testing.expectEqual(@as(usize, 1), world.get(npc, Dialog).?.index);
    try std.testing.expect(!world.has(npc, Interact.Cooldown));

    zhu.window.resetInput();
    zhu.key.set(.F, true);
    update(&world);

    try std.testing.expectEqual(null, world.getIdentity(Dialog));
    try std.testing.expectEqual(@as(usize, 0), world.get(npc, Dialog).?.index);
    try std.testing.expect(world.has(npc, Interact.Cooldown));
}

test "dialog 走远会关闭对话并开始冷却" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    _ = addTestPlayer(&world, .xy(0, 0));
    const npc = addTestNpc(&world, .xy(0, 128));
    world.setIdentity(npc, Dialog);

    update(&world);

    try std.testing.expectEqual(null, world.getIdentity(Dialog));
    try std.testing.expect(world.has(npc, Interact.Cooldown));
}
