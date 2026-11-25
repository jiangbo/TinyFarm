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
const Rest = component.map.Rest;
const Transition = component.map.Transition;
const Trigger = component.map.Trigger;

const Scene = union(enum) { title, play: ?u8 };

pub var world: World = undefined;
var allocator: std.mem.Allocator = undefined;
var mapFade: zhu.widget.Fade = .init(0.15);
var current: Scene = .title;
var pending: ?Scene = null;

pub fn init(allocator_: std.mem.Allocator) void {
    allocator = allocator_;

    world = World.init(allocator);
    world.addResource(resource.Clock{});
    world.addResource(resource.Inventory{});
    world.addResource(resource.Notice{});
    world.addResource(resource.Settings.load());

    // 存档状态先就位，UI 只持有这份长期有效的槽位切片。
    save.init();
    ui.init(&save.slots);
    title.init();
    render.init();
    enterScene(current);
}

pub fn deinit() void {
    render.deinit();
    unloadMap();
    save.deinit(allocator);
    ui.deinit();
    world.deinit();
}

pub fn update(delta: f32) void {
    zhu.mouse.captured = false;
    applyScene();

    if (updateMapFade(delta)) return;

    switch (current) {
        .title => if (title.update(&world, delta)) |req| {
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

fn updatePlayUi(req: ui.Request) void {
    switch (req) {
        .block => {},
        .title => pending = .title,
        .save => |slot| {
            if (!saveSlot(slot)) {
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
    if (world.getByIdentity(actor.Interact, Rest) != null) ui.open(.rest);
}

fn updateMapFade(delta: f32) bool {
    if (!mapFade.active()) return false;

    if (mapFade.update(delta)) |event| switch (event) {
        .covered => {
            const playerEntity = world.getIdentity(actor.Player).?;
            const request = world.get(playerEntity, Transition).?;
            exitMap();
            enterMap(request.target);
            spawnPlayer(triggerPosition(request.targetId), .down);
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
            exitMap();
        },
    }
    current, pending = .{ next, null };
    enterScene(current);
}

fn enterScene(next: Scene) void {
    switch (next) {
        .title => title.enter(&world),
        .play => |slot| enterPlay(slot),
    }
}

fn enterPlay(loadSlot: ?u8) void {
    const clock = world.getResourcePtr(resource.Clock).?;

    zhu.camera.main.scale = .all(2);

    if (loadSlot) |slot| {
        if (!load(slot)) {
            current = .title;
            title.enter(&world);
            return;
        }
        zhu.music.play("audio/01_spring_journey.ogg");
        return;
    }

    // 新游戏从固定初始地图和基础工具开始。
    clock.reset();
    world.getResourcePtr(resource.Notice).?.reset();
    world.getResourcePtr(resource.Settings).?.lightOn = false;
    save.resetMaps();

    world.resetKeepResources();
    enterMap(.home_exterior);
    const loaded = world.getResourcePtr(resource.Map).?;
    spawnPlayer(loaded.props.playerSpawn.?, .down);
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

fn saveSlot(slot: u8) bool {
    save.write(allocator, &world, slot) catch |err| {
        std.log.err("save slot {} failed: {}", .{ slot, err });
        return false;
    };
    return true;
}

fn load(slot: u8) bool {
    var record = save.read(slot) catch |err| {
        std.log.err("load slot {} failed: {}", .{ slot, err });
        return false;
    };
    defer record.deinit();

    const player = record.value.player;
    unloadMap();
    save.restore(allocator, &world, record.value);
    world.getResourcePtr(resource.Notice).?.reset();
    world.getResourcePtr(resource.Settings).?.lightOn = false;

    world.resetKeepResources();
    enterMap(player.map);
    spawnPlayer(player.position, player.facing);
    system.light.update(&world);
    system.sort.update(&world);
    ui.resetInventory();
    return true;
}

fn enterMap(id: component.map.Id) void {
    var loaded = loader.load(allocator, &world, id);
    save.applyMap(allocator, &world, &loaded);
    world.addResource(loaded);
    zhu.camera.bound = loaded.grid.size();
}

fn exitMap() void {
    save.captureMap(allocator, &world);
    unloadMap();
    world.resetKeepResources();
}

fn unloadMap() void {
    const loaded = world.getResourcePtr(resource.Map) orelse return;
    loaded.deinit(allocator);
    world.removeResource(resource.Map);
}

fn spawnPlayer(position: zhu.Vector2, facing: actor.Facing) void {
    factory.spawnPlayer(&world, position, facing);
    zhu.camera.directFollow(position);
}

fn triggerPosition(targetId: i32) zhu.Vector2 {
    var query = world.query(.{Trigger});
    while (query.next()) |row| {
        const trigger = row.get(Trigger);
        if (trigger.selfId != targetId) continue;

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
    std.debug.panic("missing map trigger {}", .{targetId});
}
