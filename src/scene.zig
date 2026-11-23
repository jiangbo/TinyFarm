const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("component.zig");
const factory = @import("factory.zig");
const input = @import("input.zig");
const map = @import("map.zig");
const render = @import("render.zig");
const storage = @import("storage.zig");
const system = @import("system/system.zig");
const title = @import("title.zig");
const ui = @import("ui.zig");

const resource = struct {
    const Clock = @import("resource/Clock.zig");
    const Inventory = @import("resource/Inventory.zig");
    const Notice = @import("resource/Notice.zig");
    const Speed = @import("resource/Speed.zig");
};

const World = ecs.World;
const actor = component.actor;
const Position = component.Position;
const Transition = component.map.Transition;
const Trigger = component.map.Trigger;

const Scene = union(enum) { title, play: ?u8 };

pub var world: World = undefined;
var allocator: zhu.Allocator = undefined;
var mapFade: zhu.widget.Fade = .init(0.15);
var current: Scene = .title;
var pending: ?Scene = null;
var config: storage.Config = .{};

pub fn init(allocator_: zhu.Allocator) void {
    allocator = allocator_;

    world = World.init(allocator);
    world.addResource(resource.Clock{});
    world.addResource(resource.Inventory{});
    world.addResource(resource.Notice{});
    world.addResource(resource.Speed{});

    // 存档状态先就位，UI 只持有这份长期有效的槽位切片。
    config = storage.init(&world);
    ui.init(.{ .slots = &storage.slots, .config = &config });
    title.init();
    map.init();
    render.init();
    enterScene(current);
}

pub fn deinit() void {
    render.deinit();
    map.deinit(allocator, &world);
    ui.deinit();
    world.deinit();
}

pub fn update(delta: f32) void {
    storage.update(&world, config);

    input.mouseCaptured = false;
    applyScene();

    if (updateMapFade(delta)) return;

    switch (current) {
        .title => if (title.update(delta)) |req| {
            switch (req) {
                .start => pending = .{ .play = null },
                .load => |slot| pending = .{ .play = slot },
            }
        },
        .play => if (ui.update(&world, delta)) |req| {
            return updatePlayUi(req);
        } else updatePlay(delta),
    }
}

pub fn draw() void {
    switch (current) {
        .title => {
            zhu.batch.beginDraw(.rgb(59, 79, 69), .{});
            title.draw();
        },
        .play => {
            render.draw(&world);

            zhu.camera.push(.window);
            defer zhu.camera.pop();
            ui.draw(&world);
            mapFade.draw(.init(.zero, zhu.camera.size), .black);
        },
    }
}

fn updatePlayUi(req: ui.Request) void {
    switch (req) {
        .block => {},
        .title => pending = .title,
        .save => |slot| {
            if (!save(slot)) {
                ui.showMessage(.{ .text = "保存失败", .fail = true });
                return;
            }
            ui.showMessage(.{ .text = "保存成功", .fail = false });
        },
        .load => |slot| {
            if (!load(slot)) {
                ui.showMessage(.{ .text = "读取失败", .fail = true });
                return;
            }
            ui.close();
        },
    }
}

fn updatePlay(delta: f32) void {
    const clock = world.getResourcePtr(resource.Clock).?;

    // 农场主循环顺序在这里显式编排，新增系统需要在这里确定位置。
    if (pending != null) return;
    if (clock.paused) return;

    // 已提交的切图请求先进入过渡，不再瞬时换图。
    if (world.getByIdentity(actor.Player, Transition) != null) {
        mapFade.fadeOut();
        return;
    }

    system.update(&world, delta);
    map.update(&world, delta);
}

fn updateMapFade(delta: f32) bool {
    if (!mapFade.active()) return false;

    if (mapFade.update(delta)) |event| switch (event) {
        .covered => {
            const playerEntity = world.getIdentity(actor.Player).?;
            const request = world.get(playerEntity, Transition).?;
            map.exit(allocator, &world);
            resetWorld();
            map.enter(allocator, &world, request.target);
            spawnPlayer(request.targetId);
            system.light.update(&world);
            system.sort.update(&world);
            mapFade.fadeIn();
        },
        .clear => {},
    };
    return true;
}

fn applyScene() void {
    const next = pending orelse return;
    ui.close();
    switch (current) {
        .title => title.exit(),
        .play => {
            mapFade = .init(0.15);
            map.exit(allocator, &world);
            resetWorld();
        },
    }
    current, pending = .{ next, null };
    enterScene(current);
}

fn enterScene(next: Scene) void {
    switch (next) {
        .title => title.enter(),
        .play => |slot| enterPlay(slot),
    }
}

fn enterPlay(loadSlot: ?u8) void {
    const clock = world.getResourcePtr(resource.Clock).?;

    zhu.camera.main.scale = .all(2);

    if (loadSlot) |slot| {
        if (!load(slot)) {
            current = .title;
            title.enter();
            return;
        }
        zhu.music.play("audio/01_spring_journey.ogg");
        return;
    }

    // 新游戏从固定初始地图和基础工具开始。
    clock.reset();
    world.getResourcePtr(resource.Notice).?.reset();
    map.resetState();

    resetWorld();
    map.enter(allocator, &world, .home_exterior);
    spawnPlayer(-1);
    system.light.update(&world);
    system.sort.update(&world);
    const inv = world.getResourcePtr(resource.Inventory).?;
    inv.reset();
    ui.resetInventory();
    _ = inv.add(.hoe, 1);
    _ = inv.add(.water, 1);
    _ = inv.add(.pickaxe, 1);
    _ = inv.add(.axe, 1);
    _ = inv.add(.sickle, 1);
    zhu.music.play("audio/01_spring_journey.ogg");
}

fn save(slot: u8) bool {
    const record = capture();
    defer record.maps.deinit(allocator);

    storage.write(slot, record) catch |err| {
        std.log.err("save slot {} failed: {}", .{ slot, err });
        return false;
    };
    return true;
}

fn load(slot: u8) bool {
    var record = storage.read(slot) catch |err| {
        std.log.err("load slot {} failed: {}", .{ slot, err });
        return false;
    };
    defer record.deinit();

    restore(record.value);
    return true;
}

fn capture() storage.Record {
    const clock = world.getResourcePtr(resource.Clock).?;
    const inv = world.getResourcePtr(resource.Inventory).?;

    return .{
        .timestamp = zhu.timestamp().toSeconds(),
        .clock = clock.*,
        .player = capturePlayer(),
        .inventory = inv.capture(),
        .maps = map.capture(allocator, &world),
    };
}

fn restore(record: storage.Record) void {
    const clock = world.getResourcePtr(resource.Clock).?;

    clock.* = record.clock;
    world.getResourcePtr(resource.Notice).?.reset();

    map.unload(allocator);
    map.restore(allocator, record.maps, clock.day);

    resetWorld();
    map.enter(allocator, &world, record.player.map);
    factory.spawnPlayer(&world, record.player.position, record.player.facing);
    zhu.camera.directFollow(record.player.position);
    system.light.update(&world);
    system.sort.update(&world);
    ui.resetInventory();
    world.getResourcePtr(resource.Inventory).?.restore(record.inventory);
}

fn spawnPlayer(targetId: i32) void {
    var position: zhu.Vector2 = .xy(311, 168);
    var query = world.query(.{Trigger});
    while (query.next()) |row| {
        const trigger = row.get(Trigger);
        if (trigger.selfId == targetId) {
            position = triggerPosition(trigger);
            break;
        }
    }
    factory.spawnPlayer(&world, position, .down);
    zhu.camera.directFollow(position);
}

fn triggerPosition(trigger: Trigger) zhu.Vector2 {
    const offset = 8;
    const center = trigger.rect.center();
    return switch (trigger.startOffset) {
        .left => .xy(trigger.rect.min.x - offset, center.y),
        .right => .xy(trigger.rect.max().x + offset, center.y),
        .top => .xy(center.x, trigger.rect.min.y - offset),
        .bottom => .xy(center.x, trigger.rect.max().y + offset),
        .none => center,
    };
}

fn capturePlayer() storage.Player {
    const entity = world.getIdentity(actor.Player).?;
    const position = world.get(entity, Position).?;
    const state = world.get(entity, actor.Actor) orelse actor.Actor{};

    return .{
        .map = map.current,
        .position = position,
        .facing = state.facing,
    };
}

fn resetWorld() void {
    // 重建世界时保留全部资源。
    world.resetKeepResources();
}
