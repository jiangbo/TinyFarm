const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("component.zig");
const factory = @import("factory.zig");
const loader = @import("loader.zig");
const render = @import("render.zig");
const save = @import("save.zig");
const system = @import("system/system.zig");
const title = @import("title.zig");
const ui = @import("ui/ui.zig");

const resource = struct {
    const Clock = @import("resource/Clock.zig");
    const Inventory = @import("resource/Inventory.zig");
    const Map = @import("resource/Map.zig");
    const Notice = @import("resource/Notice.zig");
    const Settings = @import("resource/Settings.zig");
};

const World = ecs.World;
const actor = component.actor;
const MapId = component.map.Id;
const Transition = component.map.Transition;
const Trigger = component.map.Trigger;
const defaultZoom: f32 = 2;

const Scene = enum { title, play };
const Spawn = union(enum) { start, saved: save.Player, trigger: Transition };

pub var world: World = undefined;
var allocator: std.mem.Allocator = undefined;
var fade: zhu.widget.Fade = .init(0.15);
var current: Scene = .title;
var pending: ?union(enum) {
    start,
    load,
    trigger: Transition,

    fn mapId(self: @This()) MapId {
        return switch (self) {
            .start => .home_exterior,
            .load => save.cachedMapId(),
            .trigger => |trigger| trigger.target,
        };
    }
} = null;

pub fn init(allocator_: std.mem.Allocator) void {
    allocator = allocator_;

    world = World.init(allocator);
    world.addResource(resource.Clock{});
    world.addResource(resource.Inventory{});
    world.addResource(resource.Notice{});
    world.addResource(resource.Settings.load());

    loader.init(allocator);
    ui.init();
    title.init();
    render.init();
    title.enter(&world);
}

pub fn deinit() void {
    pending = null;
    render.deinit();
    loader.deinit(&world);
    save.deinit(allocator);
    ui.deinit();
    world.deinit();
}

pub fn update(delta: f32) void {
    zhu.mouse.captured = false;
    if (updateFade(delta)) return;

    switch (current) {
        .title => {
            const req = title.update(&world, delta) orelse return;
            pending = if (req == .start) .start else .load;
        },
        .play => if (ui.update(&world, delta)) |req| switch (req) {
            .block => return,
            .title => return enterTitle(),
            .load => pending = .load,
        } else {
            updateZoom();
            system.update(&world, delta);
            render.update(&world, allocator);
            const trigger = world.get(actor.Player, Transition);
            pending = .{ .trigger = trigger orelse return };
        },
    }

    const next = pending orelse return;
    fade.fadeOut();
    loader.fetch(next.mapId());
}

pub fn draw() void {
    if (pending != null and fade.alpha() == 1) {
        zhu.camera.push(.window);
        defer zhu.camera.pop();
        zhu.batch.beginDraw(.black, .{});
        const pos = zhu.camera.size.scale(0.5);
        zhu.text.draw("Loading...", pos, .{ .anchor = .center });
        return;
    }

    switch (current) {
        .title => {
            zhu.batch.beginDraw(.rgb(59, 79, 69), .{});
            title.draw(&world);
        },
        .play => render.draw(&world),
    }

    zhu.camera.push(.window);
    defer zhu.camera.pop();
    if (current == .play) ui.draw(&world);
    fade.draw(.init(.zero, zhu.camera.size), .black);
}

fn updateFade(delta: f32) bool {
    if (!fade.active()) return false;
    const event = fade.update(delta);
    const next = pending orelse return true;
    if (fade.alpha() < 1) return true;
    if (event == .covered) {
        if (next == .trigger) save.captureMap(allocator, &world);
        loader.unload(&world);
    }
    const map = loader.load(&world, next.mapId()) orelse return true;

    pending = null;
    world.addResource(map);

    if (current == .title) {
        title.exit();
        zhu.camera.main.scale = .all(defaultZoom);
        zhu.music.play("audio/01_spring_journey.ogg", .{ .fadeIn = 0.2 });
        current = .play;
    }
    switch (next) {
        .start => startPlay(),
        .load => restorePlay(),
        .trigger => |trigger| enterMap(.{ .trigger = trigger }),
    }
    fade.fadeIn();
    return true;
}

fn enterTitle() void {
    ui.close();
    loader.unload(&world);
    title.enter(&world);
    current = .title;
}

fn startPlay() void {
    // 新游戏从固定初始地图和基础工具开始。
    world.getResourcePtr(resource.Clock).?.reset();
    world.getResourcePtr(resource.Notice).?.reset();
    world.getResourcePtr(resource.Settings).?.lightOn = false;
    save.resetMaps(allocator);

    enterMap(.start);
    const inv = world.getResourcePtr(resource.Inventory).?;
    inv.reset();
    ui.resetInventory();
    _ = inv.add(.hoe, 1);
    _ = inv.add(.water, 1);
    _ = inv.add(.pickaxe, 1);
    _ = inv.add(.axe, 1);
    _ = inv.add(.sickle, 1);
}

fn updateZoom() void {
    const scroll = zhu.mouse.scrollY;
    const reset = zhu.key.pressed(.MOUSE_MIDDLE);
    if (scroll == 0 and !reset) return;

    const currentZoom = zhu.camera.main.scale.x;
    const wheelZoom = currentZoom + scroll * 0.15;
    const zoom = if (reset) defaultZoom else std.math.clamp(wheelZoom, 1.6, 3);
    if (zoom == currentZoom) return;

    const halfView = zhu.camera.size.scale(0.5);
    const center = zhu.camera.toWorld(halfView);
    zhu.camera.main.scale = .all(zoom);
    zhu.camera.main.position = center.sub(halfView.div(zhu.camera.main.scale));
    zhu.camera.clampBound();
}

fn restorePlay() void {
    const player = save.restoreCached(allocator, &world);
    world.getResourcePtr(resource.Notice).?.reset();
    world.getResourcePtr(resource.Settings).?.lightOn = false;

    enterMap(.{ .saved = player });
    ui.resetInventory();
    ui.close();
}

fn enterMap(spawn: Spawn) void {
    const loaded = world.getResourcePtr(resource.Map).?;
    save.applyMap(allocator, &world, loaded);
    zhu.camera.bound = loaded.grid.size();

    const position = switch (spawn) {
        .start => loaded.props.playerSpawn.?,
        .saved => |player| player.position,
        .trigger => |request| triggerPosition(request.targetId),
    };
    const facing = if (spawn == .saved) spawn.saved.facing else .down;
    factory.spawnPlayer(&world, position, facing);
    zhu.camera.directFollow(position);
    system.light.update(&world);
    system.sort.update(&world);
    render.update(&world, allocator);
}

fn triggerPosition(targetId: i32) zhu.Vector2 {
    var query = world.query(.{Trigger});
    while (query.next()) |row| {
        const trigger = row.get(Trigger);
        if (trigger.selfId == targetId) return trigger.spawn;
    }
    zhu.panic("missing map trigger {}", .{targetId});
}
