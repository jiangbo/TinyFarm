const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("../component.zig");
const Clock = @import("../resource/Clock.zig");
const Settings = @import("../resource/Settings.zig");

const event = component.event;

pub fn update(world: *ecs.World, delta: f32) void {
    const clock = world.getResourcePtr(Clock).?;
    const timeScale = world.getResourcePtr(Settings).?.timeScale;

    world.clearEvent(event.DarkChanged);
    world.clearEvent(event.DayChanged);
    world.clearEvent(event.PeriodChanged);

    for (world.getEvent(event.Rest)) |rest| {
        clock.minute = 0;
        for (0..rest.hours) |_| advanceOneHour(world, clock);
    }
    world.clearEvent(event.Rest);

    clock.minute += delta * timeScale * 10.0;
    while (clock.minute >= 60.0) {
        clock.minute -= 60.0;
        advanceOneHour(world, clock);
    }
}

fn advanceOneHour(world: *ecs.World, clock: *Clock) void {
    const dark = clock.isDark();
    clock.hour += 1;

    if (clock.hour >= 24) {
        clock.hour = 0;
        clock.day += 1;
        world.addEvent(event.DayChanged{ .day = clock.day });
    }

    if (dark != clock.isDark()) world.addEvent(event.DarkChanged{});

    updatePeriod(world, clock);
}

fn updatePeriod(world: *ecs.World, clock: *Clock) void {
    const nextPeriod = currentPeriod(clock.hour);
    if (nextPeriod != clock.period) {
        clock.period = nextPeriod;
        world.addEvent(event.PeriodChanged{
            .day = clock.day,
            .hour = clock.hour,
            .period = nextPeriod,
        });
    }
}

fn currentPeriod(hour: u8) component.time.Period {
    return switch (hour) {
        4...7 => .dawn,
        8...15 => .day,
        16...19 => .dusk,
        else => .night,
    };
}

test "按存档倍率推进时间并处理分钟进位" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    world.addResource(Clock{ .hour = 6, .minute = 59.0 });
    world.addResource(Settings{ .timeScale = 2 });
    const clock = world.getResourcePtr(Clock).?;
    update(&world, 0.1);

    try std.testing.expectEqual(7, clock.hour);
    try std.testing.expectEqual(1.0, clock.minute);

    try std.testing.expectEqual(0, world.getEvent(event.DarkChanged).len);
}

test "时间推进跨天会发出新一天事件" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    world.addResource(Clock{
        .hour = 23,
        .minute = 59.0,
        .period = .night,
    });
    world.addResource(Settings{});
    const clock = world.getResourcePtr(Clock).?;
    update(&world, 0.2);

    try std.testing.expectEqual(2, clock.day);
    try std.testing.expectEqual(0, clock.hour);
    try std.testing.expectEqual(1.0, clock.minute);

    const days = world.getEvent(event.DayChanged);
    try std.testing.expectEqual(1, days.len);
    try std.testing.expectEqual(2, days[0].day);
}

test "休息按小时推进并清零分钟" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    world.addResource(Clock{
        .hour = 22,
        .minute = 37.0,
        .period = .night,
    });
    world.addResource(Settings{});
    const clock = world.getResourcePtr(Clock).?;
    world.addEvent(event.Rest{ .hours = 3 });
    update(&world, 0);

    try std.testing.expectEqual(2, clock.day);
    try std.testing.expectEqual(1, clock.hour);
    try std.testing.expectEqual(@as(f32, 0), clock.minute);

    const days = world.getEvent(event.DayChanged);
    try std.testing.expectEqual(1, days.len);
    try std.testing.expectEqual(2, days[0].day);
}

test "时段跨过边界会发出时段事件" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    world.addResource(Clock{
        .hour = 7,
        .minute = 59.0,
        .period = .dawn,
    });
    world.addResource(Settings{});
    const clock = world.getResourcePtr(Clock).?;
    update(&world, 0.2);

    try std.testing.expectEqual(currentPeriod(8), clock.period);

    const periods = world.getEvent(event.PeriodChanged);
    try std.testing.expectEqual(1, periods.len);
    try std.testing.expectEqual(currentPeriod(8), periods[0].period);
}

test "明暗变化事件覆盖自然推进和跨多个边界的休息" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    world.addResource(Clock{ .hour = 17, .minute = 59 });
    world.addResource(Settings{});

    update(&world, 0.1);
    try std.testing.expectEqual(18, world.getResourcePtr(Clock).?.hour);
    try std.testing.expectEqual(1, world.getEvent(event.DarkChanged).len);

    update(&world, 0);
    try std.testing.expectEqual(0, world.getEvent(event.DarkChanged).len);

    world.addEvent(event.Rest{ .hours = 12 });
    update(&world, 0);
    try std.testing.expectEqual(6, world.getResourcePtr(Clock).?.hour);
    try std.testing.expectEqual(1, world.getEvent(event.DarkChanged).len);

    world.addEvent(event.Rest{ .hours = 24 });
    update(&world, 0);
    try std.testing.expectEqual(6, world.getResourcePtr(Clock).?.hour);
    try std.testing.expectEqual(2, world.getEvent(event.DarkChanged).len);
}
