const std = @import("std");
const ecs = @import("ecs");

const component = @import("../component.zig");
const Clock = @import("../resource/Clock.zig");
const Map = @import("../resource/Map.zig");
const Settings = @import("../resource/Settings.zig");

const event = component.event;
const Enabled = component.light.Enabled;
const Night = component.light.Night;
const Day = component.light.Day;
const Pending = component.light.Pending;

pub fn update(world: *ecs.World) void {
    const dark = world.getResourcePtr(Clock).?.isDark();

    updatePending(world, dark);

    updateDarkChanged(world, dark);

    const player = world.getIdentity(component.actor.Player) orelse return;
    const settings = world.getResourcePtr(Settings).?;
    const allowed = !world.getResourcePtr(Map).?.outdoor or dark;
    if (settings.lightOn and allowed) {
        world.add(player, Enabled{});
    } else {
        world.remove(player, Enabled);
    }
}

fn updateDarkChanged(world: *ecs.World, dark: bool) void {
    // 时间系统已经维护当前昼夜状态，这里只消费明暗变化事件。
    if (world.getEvent(event.DarkChanged).len == 0) return;

    world.clear(Enabled);
    if (dark) {
        var query = world.query(.{Night});
        while (query.next()) |row| query.add(world, row.entity, Enabled{});
    } else {
        var query = world.query(.{Day});
        while (query.next()) |row| query.add(world, row.entity, Enabled{});
    }
}

fn updatePending(world: *ecs.World, dark: bool) void {
    // 新生成的灯光只同步一次初始昼夜状态。
    var query = world.query(.{Pending});
    while (query.next()) |row| {
        const enabled = if (dark) world.has(row.entity, Night) //
            else world.has(row.entity, Day);
        if (enabled) world.add(row.entity, Enabled{});
    }
    world.clear(Pending);
}

test "地图灯初次同步和明暗切换" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    world.addResource(Clock{ .hour = 18 });

    const night = world.createEntity();
    world.addMany(night, .{ Night{}, Pending{} });
    const day = world.createEntity();
    world.addMany(day, .{ Day{}, Pending{} });

    update(&world);
    try std.testing.expect(world.has(night, Enabled));
    try std.testing.expect(!world.has(day, Enabled));
    try std.testing.expectEqual(0, world.getComponents(Pending).len);

    world.getResourcePtr(Clock).?.hour = 6;
    world.addEvent(event.DarkChanged{});
    update(&world);
    try std.testing.expect(!world.has(night, Enabled));
    try std.testing.expect(world.has(day, Enabled));
}

test "随身灯遵守手动开关、室内外和昼夜边界" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    world.addResource(Clock{});
    world.addResource(Settings{});
    world.addResource(Map{});
    const player = world.createIdentity(component.actor.Player);

    const Case = struct { outdoor: bool, hour: u8, on: bool, enabled: bool };
    const cases = [_]Case{
        .{ .outdoor = true, .hour = 17, .on = true, .enabled = false },
        .{ .outdoor = true, .hour = 18, .on = true, .enabled = true },
        .{ .outdoor = true, .hour = 6, .on = true, .enabled = false },
        .{ .outdoor = false, .hour = 6, .on = true, .enabled = true },
        .{ .outdoor = false, .hour = 6, .on = false, .enabled = false },
    };
    for (cases) |case| {
        world.getResourcePtr(Map).?.outdoor = case.outdoor;
        world.getResourcePtr(Clock).?.hour = case.hour;
        world.getResourcePtr(Settings).?.lightOn = case.on;
        update(&world);
        try std.testing.expectEqual(case.enabled, world.has(player, Enabled));
    }
}
