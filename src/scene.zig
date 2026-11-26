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
const Transition = component.map.Transition;
const Trigger = component.map.Trigger;
const defaultZoom: f32 = 2;

const Scene = enum { title, play };
const Spawn = union(enum) {
    start: component.map.Id,
    saved: save.Player,
    trigger: Transition,
};

pub var world: World = undefined;
var allocator: std.mem.Allocator = undefined;
var mapFade: zhu.widget.Fade = .init(0.15);
var current: Scene = .title;
var pending: ?union(Scene) { title, play: title.Request } = null;

pub fn init(allocator_: std.mem.Allocator) void {
    allocator = allocator_;

    world = World.init(allocator);
    world.addResource(resource.Clock{});
    world.addResource(resource.Inventory{});
    world.addResource(resource.Notice{});
    world.addResource(resource.Settings.load());

    ui.init();
    title.init();
    render.init();
    title.enter(&world);
}

pub fn deinit() void {
    pending = null;
    render.deinit();
    unloadMap();
    save.deinit(allocator);
    ui.deinit();
    world.deinit();
}

pub fn update(delta: f32) void {
    zhu.mouse.captured = false;
    applyScene();

    switch (current) {
        .title => if (title.update(&world, delta)) |req| {
            pending = .{ .play = req };
        },
        .play => {
            if (updateMapFade(delta)) return;
            if (ui.update(&world, delta)) |req| switch (req) {
                .block => {},
                .title => pending = .title,
                .load => restorePlay(),
            } else {
                updateZoom();
                system.update(&world, delta);
            }
        },
    }
}

pub fn draw() void {
    switch (current) {
        .title => {
            zhu.batch.beginDraw(.rgb(59, 79, 69), .{});
            title.draw(&world);
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

fn updateMapFade(delta: f32) bool {
    if (!mapFade.active()) {
        if (!world.has(actor.Player, Transition)) return false;
        mapFade.fadeOut();
    }

    if (mapFade.update(delta)) |event| switch (event) {
        .covered => {
            const request = world.get(actor.Player, Transition).?;
            save.captureMap(allocator, &world);
            unloadMap();
            enterMap(.{ .trigger = request });
            mapFade.fadeIn();
        },
        .clear => {},
    };
    return true;
}

fn applyScene() void {
    const next = pending orelse return;
    pending = null;

    ui.close();
    switch (current) {
        .title => title.exit(),
        .play => {
            mapFade = .init(0.15);
            unloadMap();
        },
    }
    current = next;
    switch (next) {
        .title => title.enter(&world),
        .play => |req| enterPlay(req),
    }
}

fn enterPlay(req: title.Request) void {
    const clock = world.getResourcePtr(resource.Clock).?;

    zhu.camera.main.scale = .all(defaultZoom);

    if (req == .load) {
        restorePlay();
        zhu.music.play("audio/01_spring_journey.ogg");
        return;
    }

    // 新游戏从固定初始地图和基础工具开始。
    clock.reset();
    world.getResourcePtr(resource.Notice).?.reset();
    world.getResourcePtr(resource.Settings).?.lightOn = false;
    save.resetMaps();

    enterMap(.{ .start = .home_exterior });
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
    unloadMap();
    world.getResourcePtr(resource.Notice).?.reset();
    world.getResourcePtr(resource.Settings).?.lightOn = false;

    enterMap(.{ .saved = player });
    ui.resetInventory();
    ui.close();
}

fn enterMap(spawn: Spawn) void {
    const id = switch (spawn) {
        .start => |id| id,
        .saved => |player| player.map,
        .trigger => |request| request.target,
    };
    var loaded = loader.load(allocator, &world, id);
    save.applyMap(allocator, &world, &loaded);
    world.addResource(loaded);
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
}

fn unloadMap() void {
    const loaded = world.getResourcePtr(resource.Map) orelse return;
    loaded.deinit(allocator);
    world.removeResource(resource.Map);
    world.resetKeepResources();
}

fn triggerPosition(targetId: i32) zhu.Vector2 {
    var query = world.query(.{Trigger});
    while (query.next()) |row| {
        const trigger = row.get(Trigger);
        if (trigger.selfId == targetId) return trigger.spawn;
    }
    std.debug.panic("missing map trigger {}", .{targetId});
}
