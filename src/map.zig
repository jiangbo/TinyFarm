const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("component.zig");
const factory = @import("factory.zig");
const loader = @import("map/loader.zig");
const storage = @import("storage.zig");
const Clock = @import("resource/Clock.zig");
const Map = @import("resource/Map.zig");

const spatial = zhu.extend.spatial;
const World = ecs.World;
const Entity = ecs.Entity;
const actor = component.actor;
const render = component.render;
const farm = component.farm;
const item = component.item;
const motion = component.motion;
const Object = storage.Object;
const Tile = storage.Tile;
const SaveMap = storage.Map;
pub const Id = component.map.Id;
pub const StartOffset = component.map.StartOffset;
pub const Hit = component.map.Hit;

var states: std.EnumArray(Id, SaveMap) = .initFill(.{});

pub fn deinit(gpa: std.mem.Allocator, world: *World) void {
    unload(gpa, world);
    for (&states.values) |*state| {
        gpa.free(state.tiles);
        state.* = .{};
    }
}

pub fn enter(gpa: std.mem.Allocator, world: *World, id: Id) void {
    var current = loader.load(gpa, world, id);
    restoreCurrent(gpa, world, &current);
    world.addResource(current);
    zhu.camera.bound = current.grid.size();

    // 原始地图没有住宅室外与城镇的连接，由游戏补充。
    const trigger: component.map.Trigger = switch (id) {
        .home_exterior => .{
            .rect = .init(.xy(552, 227), .xy(7, 25)),
            .selfId = 2,
            .targetId = 2,
            .targetMap = .town,
            .startOffset = .left,
        },
        .town => .{
            .rect = .init(.xy(1, 227), .xy(7, 25)),
            .selfId = 2,
            .targetId = 2,
            .targetMap = .home_exterior,
            .startOffset = .right,
        },
        else => return,
    };
    _ = factory.spawnMapTrigger(world, trigger);
}

pub fn exit(gpa: std.mem.Allocator, world: *World) void {
    saveCurrent(gpa, world);
    unload(gpa, world);
}

pub fn unload(gpa: std.mem.Allocator, world: *World) void {
    const current = world.getResourcePtr(Map) orelse return;
    current.deinit(gpa);
    world.removeResource(Map);
}

pub fn resetState() void {
    for (std.enums.values(Id)) |id| {
        const entry = states.getPtr(id);
        for (entry.tiles, 0..) |*tile, index| {
            tile.* = .{ .index = @intCast(index) };
        }
        entry.day = 1;
    }
}

pub fn capture(gpa: std.mem.Allocator, world: *const World) storage.MapRecord {
    saveCurrent(gpa, world);
    var result: storage.MapRecord = .{};

    for (std.enums.values(Id)) |id| {
        const state = states.getPtrConst(id);
        result.maps.set(id, .{
            .day = state.day,
            .tiles = captureTiles(gpa, state),
        });
    }

    return result;
}

pub fn restore(gpa: std.mem.Allocator, saved: storage.MapRecord, day: u32) void {
    resetState();
    for (std.enums.values(Id)) |id| {
        restoreMap(gpa, id, saved.maps.get(id), day);
    }
}

// 清除地图上的默认产出对象，并记录为 gone，避免后续恢复时重新生成。
pub fn clearProduct(world: *World, position: zhu.Vector2) void {
    const current = world.getResourcePtr(Map).?;
    clearProductIndex(world, current, current.grid.worldToIndex(position).?);
}

fn saveCurrent(gpa: std.mem.Allocator, world: *const World) void {
    const day = world.getResourcePtr(Clock).?.*.day;
    const current = world.getResourcePtr(Map).?;
    const state = ensure(gpa, current.id, current.tiles.len, day);
    for (current.tiles, 0..) |tile, index| {
        var saved = &state.tiles[index];
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

fn restoreCurrent(gpa: std.mem.Allocator, world: *World, current: *Map) void {
    const day = world.getResourcePtr(Clock).?.day;
    const state = ensure(gpa, current.id, current.tiles.len, day);
    advanceState(state, day);

    for (state.tiles, 0..) |saved, index| {
        const tile = &current.tiles[index];
        tile.ground = saved.ground;

        const object = saved.object orelse continue;
        restoreObject(world, current, index, object);
    }

    state.day = day;
}

fn ensure(gpa: std.mem.Allocator, id: Id, count: usize, day: u32) *SaveMap {
    const entry = states.getPtr(id);
    if (entry.tiles.len != 0) return entry;

    entry.tiles = gpa.alloc(Tile, count) catch zhu.oom();
    for (entry.tiles, 0..) |*tile, index| {
        tile.* = .{ .index = @intCast(index) };
    }
    entry.day = day;
    return entry;
}

fn captureTiles(gpa: std.mem.Allocator, state: *const SaveMap) []Tile {
    var list: std.ArrayList(Tile) = .empty;

    if (state.tiles.len == 0) return &.{};

    for (state.tiles) |tile| {
        if (tile.ground == null and tile.object == null) continue;
        list.append(gpa, tile) catch zhu.oom();
    }

    return list.toOwnedSlice(gpa) catch zhu.oom();
}

fn restoreMap(gpa: std.mem.Allocator, id: Id, saved: SaveMap, day: u32) void {
    const mapData = loader.definition(id);
    const count = mapData.grid.count();
    const state = ensure(gpa, id, count, day);

    for (saved.tiles) |tileSave| {
        std.debug.assert(tileSave.index < state.tiles.len);

        const index: usize = @intCast(tileSave.index);
        const tile = &state.tiles[index];
        tile.ground = tileSave.ground;
        tile.object = tileSave.object;
    }

    state.day = saved.day;
}

fn objectAt(world: *const World, tile: Map.Tile) ?Object {
    const object = tile.object orelse return null;
    return switch (object.kind) {
        .crop => .{ .crop = world.get(object.entity, farm.Crop).? },
        .chest => .{ .chest = world.get(object.entity, item.Chest).? },
        .product => .{ .product = world.get(object.entity, item.Product).?.health },
    };
}

fn restoreObject(world: *World, current: *Map, index: usize, data: Object) void {
    switch (data) {
        .gone => clearProductIndex(world, current, index),
        .crop => |crop| {
            const position = current.grid.indexToWorld(index);
            const entity = factory.spawnCrop(world, position, crop.kind);
            world.getPtr(entity, farm.Crop).?.* = crop;
            refreshCropSprite(world, entity, crop);
            current.tiles[index].set(.crop, entity);
        },
        .chest => |saved| {
            const object = current.tiles[index].object.?;
            std.debug.assert(object.kind == .chest);
            const chest = world.getPtr(object.entity, item.Chest).?;
            chest.* = saved;
            if (!saved.opened) return;

            const animation = world.getPtr(
                object.entity,
                actor.Animation,
            ).?;
            const sprite = world.getPtr(object.entity, render.Sprite).?;
            // 已打开宝箱只需要固定打开帧，后续不再参与动画系统。
            sprite.image = animation.subImageAt(animation.source.frames.len - 1);
            world.remove(object.entity, actor.Animation);
            world.remove(object.entity, motion.Shape);
        },
        .product => |saved| {
            const object = current.tiles[index].object.?;
            std.debug.assert(object.kind == .product);
            world.getPtr(object.entity, item.Product).?.health = saved;
        },
    }
}

fn clearProductIndex(world: *World, current: *Map, index: usize) void {
    const object = current.tiles[index].object.?;
    std.debug.assert(object.kind == .product);
    if (world.get(object.entity, component.map.SolidRange)) |range| {
        for (current.solidAreas(range)) |*area| area.* = .init(.zero, .zero);
    }
    world.destroyEntity(object.entity);
    clearProductTiles(current.tiles, object.entity);
    current.tiles[index].gone = .product;
}

// 只清引用，不写 gone；gone 只记录在触发销毁的那一个格子上。
fn clearProductTiles(tiles: []Map.Tile, entity: ecs.Entity) void {
    for (tiles) |*tile| {
        if (tile.get(.product) == entity) tile.object = null;
    }
}

fn advanceState(state: *SaveMap, day: u32) void {
    if (day <= state.day) return;

    const days = day - state.day;
    for (0..days) |_| advanceStateOneDay(state);
    state.day = day;
}

fn advanceStateOneDay(state: *SaveMap) void {
    for (state.tiles) |*tile| {
        const watered = tile.ground == .wet;
        // 浇水只影响当天，跨天后湿地统一变回干地。
        if (tile.ground == .wet) tile.ground = .dry;

        const object = tile.object orelse continue;
        switch (object) {
            .crop => |cropState| {
                var crop = cropState;
                _ = advanceCropOneDay(&crop, watered);
                tile.object = .{ .crop = crop };
            },
            .gone, .chest, .product => {},
        }
    }
}

pub fn advanceCropOneDay(crop: *farm.Crop, watered: bool) bool {
    if (crop.stage == .mature) return false;

    crop.next -= if (watered) 2 else 1;
    if (crop.next > 0) return false;

    crop.stage = zhu.enums.next(crop.stage);
    crop.next = factory.cropStage(crop.kind, crop.stage).duration;
    return true;
}

pub fn refreshCropSprite(world: *const World, entity: Entity, crop: farm.Crop) void {
    const cfg = factory.cropStage(crop.kind, crop.stage);
    world.getPtr(entity, render.Sprite).?.* = .{
        .image = factory.resolveImage(cfg.sprite),
        .offset = cfg.sprite.offset,
    };
    if (crop.stage == .seed) return;
    world.getPtr(entity, render.Render).?.layer = .actor;
}

test "地图状态作物会按离线天数推进" {
    var tiles = [_]storage.Tile{.{
        .ground = .wet,
        .object = .{ .crop = .{
            .kind = .strawberry,
            .stage = .seed,
            .next = 2,
        } },
    }};
    var state = storage.Map{
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
    var tiles = [_]storage.Tile{.{
        .ground = .wet,
        .object = .{ .crop = .{
            .kind = .strawberry,
            .stage = .seed,
            .next = 4,
        } },
    }};
    var state = storage.Map{
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

test "当前地图和离线地图跨天推进规则一致" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    world.addResource(Map.init(gpa, .school, testGrid));
    const current = world.getResourcePtr(Map).?;
    defer current.deinit(gpa);

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

    var tiles = [_]storage.Tile{.{
        .ground = .wet,
        .object = .{ .crop = .{
            .kind = .strawberry,
            .stage = .seed,
            .next = 2,
        } },
    }};
    var state = storage.Map{
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
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    world.addResource(Map.init(gpa, .school, testGrid));
    const current = world.getResourcePtr(Map).?;
    defer current.deinit(gpa);

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

    restoreObject(&world, current, 0, .{ .chest = .{ .opened = true } });

    try std.testing.expect(world.get(chest, item.Chest).?.opened);
    try std.testing.expect(!world.has(chest, actor.Animation));
    try std.testing.expectEqual(
        16,
        world.get(chest, render.Sprite).?.image.offset.x,
    );
}

test "恢复地图产出对象只写回生命" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    world.addResource(Map.init(gpa, .school, testGrid));
    const current = world.getResourcePtr(Map).?;
    defer current.deinit(gpa);

    const entity = world.createEntity();
    world.add(entity, item.Product{ .drop = .one(.stone), .health = 1 });
    current.tiles[0].object = .{ .kind = .product, .entity = entity };

    restoreObject(&world, current, 0, .{ .product = 4 });

    const product = world.get(entity, item.Product).?;
    try std.testing.expectEqual(.stone, product.drop.item);
    try std.testing.expectEqual(1, product.drop.count);
    try std.testing.expectEqual(4, product.health);
}

test "恢复已移除的产出对象时只清除它自己的阻挡" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();

    var current = Map.init(gpa, .school, testGrid);
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

    restoreObject(&world, &current, 0, .gone);

    try std.testing.expectEqual(null, current.tiles[0].object);
    try std.testing.expectEqual(.product, current.tiles[0].gone);
    try std.testing.expect(!world.has(entity, item.Product));
    try std.testing.expect(!current.collision.overlaps(productArea));
    try std.testing.expect(current.collision.overlaps(neighborArea));
}
