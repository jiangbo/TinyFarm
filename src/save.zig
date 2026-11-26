const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("component.zig");
const Clock = @import("resource/Clock.zig");
const Inventory = @import("resource/Inventory.zig");
const MapResource = @import("resource/Map.zig");
const Settings = @import("resource/Settings.zig");
const factory = @import("factory.zig");
const loader = @import("loader.zig");

const World = ecs.World;
const MapId = component.map.Id;
const spatial = zhu.extend.spatial;
const actor = component.actor;
const farm = component.farm;
const item = component.item;
const motion = component.motion;
const render = component.render;

pub const Summary = struct { day: u32 = 0, timestamp: i64 = 0 };

pub const Slot = union(enum) { empty, valid: Summary };

pub const Player = struct {
    map: component.map.Id = .town,
    position: zhu.Vector2 = .zero,
    facing: component.actor.Facing = .down,
};

pub const Object = union(enum) {
    gone,
    crop: component.farm.Crop,
    chest: component.item.Chest,
    product: u8,
};

pub const Tile = struct {
    index: u32 = 0,
    ground: ?component.farm.Ground = null,
    object: ?Object = null,
};

pub const Map = struct {
    day: u32 = 0,
    tiles: []Tile = &.{},
};

pub const MapRecord = struct {
    maps: std.EnumArray(MapId, Map) = .initFill(.{}),

    pub fn deinit(self: MapRecord, gpa: std.mem.Allocator) void {
        for (std.enums.values(MapId)) |id| {
            gpa.free(self.maps.get(id).tiles);
        }
    }
};

pub const Record = struct {
    timestamp: i64 = 0,
    clock: Clock = .{},
    player: Player = .{},
    inventory: Inventory = .{},
    maps: MapRecord = .{},
    timeScale: f32 = 1,
};

const slotsPath = "saves/slots.bin";

var slots: ?[10]Slot = null;
var states: MapRecord = .{};

pub fn getSlots() *const [10]Slot {
    if (slots) |*loaded| return loaded;
    slots = zhu.storage.readValue([10]Slot, slotsPath) catch |err|
        switch (err) {
            error.FileNotFound => @splat(.empty),
            else => std.debug.panic("load {s} failed: {}", .{ slotsPath, err }),
        };
    return &slots.?;
}

pub fn read(slot: u8) !zhu.storage.Loaded(Record) {
    var buffer: [32]u8 = undefined;
    const path = zhu.formatZ(&buffer, "saves/slot{d}.bin", .{slot});
    const record = try zhu.storage.readArena(Record, path);
    std.log.info("game loaded: {s}", .{path});
    return record;
}

pub fn write(gpa: std.mem.Allocator, world: *const World, slot: u8) !void {
    var nextSlots = getSlots().*;
    const record = capture(gpa, world);
    defer record.maps.deinit(gpa);

    var buffer: [32]u8 = undefined;
    const path = zhu.formatZ(&buffer, "saves/slot{d}.bin", .{slot});

    nextSlots[slot] = .{ .valid = .{
        .day = record.clock.day,
        .timestamp = record.timestamp,
    } };
    try zhu.storage.writeValue(path, record);
    try zhu.storage.writeValue(slotsPath, nextSlots);
    slots = nextSlots;
    std.log.info("game saved: {s}", .{path});
}

pub fn deinit(gpa: std.mem.Allocator) void {
    slots = null;
    states.deinit(gpa);
    states = .{};
}

fn capture(gpa: std.mem.Allocator, world: *const World) Record {
    const player = world.getIdentity(actor.Player).?;
    const character = world.get(player, actor.Actor) orelse actor.Actor{};

    return .{
        .timestamp = zhu.timestamp().toSeconds(),
        .clock = world.getResourcePtr(Clock).?.*,
        .player = .{
            .map = world.getResourcePtr(MapResource).?.id,
            .position = world.get(player, component.Position).?,
            .facing = character.facing,
        },
        .inventory = world.getResourcePtr(Inventory).?.*,
        .maps = captureMaps(gpa, world),
        .timeScale = world.getResourcePtr(Settings).?.timeScale,
    };
}

pub fn restore(gpa: std.mem.Allocator, world: *World, record: Record) void {
    world.getResourcePtr(Clock).?.* = record.clock;
    world.getResourcePtr(Settings).?.timeScale = record.timeScale;
    restoreMaps(gpa, record.maps, record.clock.day);
    world.getResourcePtr(Inventory).?.* = record.inventory;
}

pub fn resetMaps() void {
    for (std.enums.values(MapId)) |id| {
        const entry = states.maps.getPtr(id);
        for (entry.tiles, 0..) |*tile, index| {
            tile.* = .{ .index = @intCast(index) };
        }
        entry.day = 1;
    }
}

pub fn captureMap(gpa: std.mem.Allocator, world: *const World) void {
    const current = world.getResourcePtr(MapResource).?;
    const day = world.getResourcePtr(Clock).?.day;
    const state = ensure(gpa, current.id, current.tiles.len, day);
    for (current.tiles, state.tiles) |tile, *saved| {
        saved.ground = tile.ground;
        if (objectAt(world, tile)) |object| {
            saved.object = object;
        } else if (tile.gone == .product) {
            saved.object = .gone;
        } else {
            saved.object = null;
        }
    }
    state.day = day;
}

pub fn applyMap(gpa: std.mem.Allocator, world: *World, current: *MapResource) void {
    const day = world.getResourcePtr(Clock).?.day;
    const state = ensure(gpa, current.id, current.tiles.len, day);
    advanceState(state, day);
    applyTiles(current, world, state.tiles);
}

fn captureMaps(gpa: std.mem.Allocator, world: *const World) MapRecord {
    captureMap(gpa, world);
    var result: MapRecord = .{};

    for (std.enums.values(MapId)) |id| {
        const state = states.maps.getPtrConst(id);
        result.maps.set(id, .{
            .day = state.day,
            .tiles = captureTiles(gpa, state),
        });
    }

    return result;
}

fn restoreMaps(gpa: std.mem.Allocator, saved: MapRecord, day: u32) void {
    resetMaps();
    for (std.enums.values(MapId)) |id| {
        const count = loader.definition(id).grid.count();
        restoreMap(ensure(gpa, id, count, day), saved.maps.get(id));
    }
}

fn ensure(gpa: std.mem.Allocator, id: MapId, count: usize, day: u32) *Map {
    const entry = states.maps.getPtr(id);
    if (entry.tiles.len != 0) return entry;

    entry.tiles = gpa.alloc(Tile, count) catch zhu.oom();
    for (entry.tiles, 0..) |*tile, index| {
        tile.* = .{ .index = @intCast(index) };
    }
    entry.day = day;
    return entry;
}

fn captureTiles(gpa: std.mem.Allocator, state: *const Map) []Tile {
    var list: std.ArrayList(Tile) = .empty;

    if (state.tiles.len == 0) return &.{};

    for (state.tiles) |tile| {
        if (tile.ground == null and tile.object == null) continue;
        list.append(gpa, tile) catch zhu.oom();
    }

    return list.toOwnedSlice(gpa) catch zhu.oom();
}

fn restoreMap(state: *Map, saved: Map) void {
    for (saved.tiles) |tileSave| {
        std.debug.assert(tileSave.index < state.tiles.len);

        const index: usize = @intCast(tileSave.index);
        const tile = &state.tiles[index];
        tile.ground = tileSave.ground;
        tile.object = tileSave.object;
    }

    state.day = saved.day;
}

fn advanceState(state: *Map, day: u32) void {
    if (day <= state.day) return;

    const days = day - state.day;
    for (0..days) |_| advanceStateOneDay(state);
    state.day = day;
}

fn advanceStateOneDay(state: *Map) void {
    for (state.tiles) |*tile| {
        const watered = tile.ground == .wet;
        // 浇水只影响当天，跨天后湿地统一变回干地。
        if (tile.ground == .wet) tile.ground = .dry;

        const object = tile.object orelse continue;
        switch (object) {
            .crop => |cropState| {
                var crop = cropState;
                _ = factory.advanceCropOneDay(&crop, watered);
                tile.object = .{ .crop = crop };
            },
            .gone, .chest, .product => {},
        }
    }
}

fn applyTiles(current: *MapResource, world: *World, tiles: []const Tile) void {
    for (tiles) |saved| {
        current.tiles[saved.index].ground = saved.ground;
        const object = saved.object orelse continue;
        restoreObject(current, world, saved.index, object);
    }
}

fn objectAt(world: *const World, tile: MapResource.Tile) ?Object {
    const object = tile.object orelse return null;
    return switch (object.kind) {
        .crop => .{ .crop = world.get(object.entity, farm.Crop).? },
        .chest => .{ .chest = world.get(object.entity, item.Chest).? },
        .product => .{ .product = world.get(object.entity, item.Product).?.health },
    };
}

fn restoreObject(map: *MapResource, world: *World, index: usize, data: Object) void {
    switch (data) {
        .gone => {
            const entity = map.tiles[index].get(.product).?;
            const solid = world.get(entity, component.map.SolidRange);
            map.clearProduct(index, solid);
            world.destroyEntity(entity);
        },
        .crop => |crop| {
            const position = map.grid.indexToWorld(index);
            const entity = factory.spawnCrop(world, position, crop);
            map.tiles[index].set(.crop, entity);
        },
        .chest => |saved| {
            const object = map.tiles[index].object.?;
            std.debug.assert(object.kind == .chest);
            const chest = world.getPtr(object.entity, item.Chest).?;
            chest.* = saved;
            if (!saved.opened) return;

            const animation = world.getPtr(
                object.entity,
                actor.Animation,
            ).?;
            const sprite = world.getPtr(object.entity, render.Sprite).?;
            // 已打开的宝箱固定显示最后一帧。
            sprite.image = animation.subImageAt(animation.source.frames.len - 1);
            world.remove(object.entity, actor.Animation);
            world.remove(object.entity, motion.Shape);
        },
        .product => |saved| {
            const object = map.tiles[index].object.?;
            std.debug.assert(object.kind == .product);
            world.getPtr(object.entity, item.Product).?.health = saved;
        },
    }
}

test "地图状态作物会按离线天数推进" {
    var tiles = [_]Tile{.{
        .ground = .wet,
        .object = .{ .crop = .{
            .kind = .strawberry,
            .stage = .seed,
            .next = 2,
        } },
    }};
    var state = Map{
        .day = 1,
        .tiles = &tiles,
    };
    advanceState(&state, 2);

    const crop = switch (state.tiles[0].object.?) {
        .crop => |crop| crop,
        else => unreachable,
    };
    try std.testing.expectEqual(farm.GrowthEnum.sprout, crop.stage);
    try std.testing.expectEqual(
        factory.cropStage(.strawberry, .sprout).duration,
        crop.next,
    );
    try std.testing.expectEqual(
        component.farm.Ground.dry,
        state.tiles[0].ground,
    );
    try std.testing.expectEqual(@as(u32, 2), state.day);
}

test "湿地离线跨天只加速一天" {
    var tiles = [_]Tile{.{
        .ground = .wet,
        .object = .{ .crop = .{
            .kind = .strawberry,
            .stage = .seed,
            .next = 4,
        } },
    }};
    var state = Map{
        .day = 1,
        .tiles = &tiles,
    };
    advanceState(&state, 3);

    const crop = switch (state.tiles[0].object.?) {
        .crop => |crop| crop,
        else => unreachable,
    };
    try std.testing.expectEqual(farm.GrowthEnum.seed, crop.stage);
    try std.testing.expectEqual(@as(f32, 1), crop.next);
    try std.testing.expectEqual(
        component.farm.Ground.dry,
        state.tiles[0].ground,
    );
}

const testGrid: spatial.Grid = .{ .width = 10, .height = 12, .cellSide = 16 };

fn initTestMap() MapResource {
    return MapResource.init(std.testing.allocator, .school, testGrid);
}

test "当前地图和离线地图跨天推进规则一致" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    world.addResource(initTestMap());
    const current = world.getResourcePtr(MapResource).?;
    defer current.deinit(std.testing.allocator);

    const target = zhu.Vector2.xy(32, 48);
    const cropEntity = world.createEntity();
    world.add(cropEntity, farm.Crop{
        .kind = .strawberry,
        .stage = .seed,
        .next = 2,
    });
    world.add(cropEntity, render.Sprite{ .image = .{} });
    world.add(cropEntity, render.Render{ .layer = .crop });
    const tile = current.getTile(target).?;
    tile.ground = .wet;
    tile.set(.crop, cropEntity);
    world.addEvent(component.event.DayChanged{ .day = 2 });

    var tiles = [_]Tile{.{
        .ground = .wet,
        .object = .{ .crop = .{
            .kind = .strawberry,
            .stage = .seed,
            .next = 2,
        } },
    }};
    var state = Map{
        .day = 1,
        .tiles = &tiles,
    };
    @import("system/farm.zig").update(&world);
    advanceState(&state, 2);

    const currentCrop = world.get(cropEntity, farm.Crop).?;
    const offlineCrop = switch (state.tiles[0].object.?) {
        .crop => |crop| crop,
        else => unreachable,
    };
    try std.testing.expectEqual(offlineCrop.stage, currentCrop.stage);
    try std.testing.expectEqual(offlineCrop.next, currentCrop.next);
    try std.testing.expectEqual(state.tiles[0].ground, tile.ground);
}

test "恢复已打开宝箱会移除动画组件" {
    var current = initTestMap();
    defer current.deinit(std.testing.allocator);

    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const frames = [_]zhu.graphics.Frame{
        .{ .offset = .xy(0, 0), .duration = 0.1 },
        .{ .offset = .xy(16, 0), .duration = 0.1 },
    };
    const image = zhu.Image{ .size = .xy(32, 16) };

    const chest = world.createEntity();
    world.add(chest, item.Chest{});
    world.add(chest, actor.Animation.init(image, .xy(16, 16), &frames));
    world.add(chest, render.Sprite{ .image = image });
    current.tiles[0].object = .{ .kind = .chest, .entity = chest };

    applyTiles(&current, &world, &.{.{ .object = .{ .chest = .{ .opened = true } } }});

    try std.testing.expect(world.get(chest, item.Chest).?.opened);
    try std.testing.expect(!world.has(chest, actor.Animation));
    try std.testing.expectEqual(
        16,
        world.get(chest, render.Sprite).?.image.offset.x,
    );
}

test "恢复地图产出对象只写回生命" {
    var current = initTestMap();
    defer current.deinit(std.testing.allocator);

    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    const entity = world.createEntity();
    world.add(entity, item.Product{ .drop = .one(.stone), .health = 1 });
    current.tiles[0].object = .{ .kind = .product, .entity = entity };

    applyTiles(&current, &world, &.{.{ .object = .{ .product = 4 } }});

    const product = world.get(entity, item.Product).?;
    try std.testing.expectEqual(.stone, product.drop.item);
    try std.testing.expectEqual(1, product.drop.count);
    try std.testing.expectEqual(4, product.health);
}

test "恢复已移除的产出对象时只清除它自己的阻挡" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();

    var current = MapResource.init(gpa, .school, testGrid);
    defer current.deinit(gpa);
    try current.areas.appendSlice(gpa, &.{
        .init(.xy(4, 0), .xy(4, 16)),
        .init(.xy(8, 0), .xy(4, 16)),
    });
    const areas = current.areas.items;
    current.collision.index = try spatial.StaticIndex.build(gpa, testGrid, areas);

    const entity = world.createEntity();
    world.add(entity, item.Product{ .drop = .one(.stone), .health = 1 });
    current.tiles[0].object = .{ .kind = .product, .entity = entity };
    world.add(entity, component.map.SolidRange{ .start = 0, .count = 1 });

    const productArea: zhu.Shape = .{ .rect = .init(.xy(5, 1), .one) };
    const neighborArea: zhu.Shape = .{ .rect = .init(.xy(9, 1), .one) };
    try std.testing.expect(current.collision.overlaps(productArea));
    try std.testing.expect(current.collision.overlaps(neighborArea));

    applyTiles(&current, &world, &.{.{ .object = .gone }});

    try std.testing.expectEqual(null, current.tiles[0].object);
    try std.testing.expectEqual(.product, current.tiles[0].gone);
    try std.testing.expect(!world.has(entity, item.Product));
    try std.testing.expect(!current.collision.overlaps(productArea));
    try std.testing.expect(current.collision.overlaps(neighborArea));
}
