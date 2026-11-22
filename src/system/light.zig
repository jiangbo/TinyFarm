const std = @import("std");
const ecs = @import("ecs");

const component = @import("../component.zig");
const map = @import("../map.zig");
const Clock = @import("../resource/Clock.zig");

const event = component.event;
const MapId = component.map.Id;
const Disabled = component.light.Disabled;
const Night = component.light.Night;
const Day = component.light.Day;
const Pending = component.light.Pending;

pub fn update(world: *ecs.World) void {
    const clock = world.getResourcePtr(Clock).?;

    updatePending(world, clock.isDark());

    // 室内地图光源始终启用，不做时间切换
    if (!isOutdoor(map.current)) {
        world.clear(Disabled);
        return;
    }

    // 时间系统已经维护当前昼夜状态，这里只消费整点事件。
    if (world.getEvent(event.HourChanged).len == 0) return;

    world.clear(Disabled);
    if (clock.isDark()) {
        var query = world.query(.{Day});
        while (query.next()) |row| query.add(world, row.entity, Disabled{});
    } else {
        var query = world.query(.{Night});
        while (query.next()) |row| query.add(world, row.entity, Disabled{});
    }
}

fn updatePending(world: *ecs.World, dark: bool) void {
    // 新生成的灯光只同步一次初始昼夜状态。
    var query = world.query(.{Pending});
    while (query.next()) |row| {
        const enabled = if (dark) world.has(row.entity, Night) //
            else world.has(row.entity, Day);
        if (enabled) world.remove(row.entity, Disabled);
    }
    world.clear(Pending);
}

fn isOutdoor(id: MapId) bool {
    // 光照系统只关心昼夜是否影响当前地图。
    return switch (id) {
        .town, .home_exterior => true,
        .school, .home_interior => false,
    };
}

test "light update 夜晚启用夜灯禁用日灯" {
    map.current = .home_exterior; // 设置为室外地图
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    world.addResource(Clock{ .hour = 18 });

    const night = world.createEntity();
    world.add(night, Night{});
    world.add(night, Disabled{});

    const day = world.createEntity();
    world.add(day, Day{});

    world.addEvent(event.HourChanged{});

    update(&world);

    try std.testing.expect(!world.has(night, Disabled));
    try std.testing.expect(world.has(day, Disabled));
}

test "light update 白天启用日灯禁用夜灯" {
    map.current = .home_exterior; // 设置为室外地图
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    world.addResource(Clock{ .hour = 12 });

    const night = world.createEntity();
    world.add(night, Night{});

    const day = world.createEntity();
    world.add(day, Day{});
    world.add(day, Disabled{});

    world.addEvent(event.HourChanged{});

    update(&world);

    try std.testing.expect(world.has(night, Disabled));
    try std.testing.expect(!world.has(day, Disabled));
}
