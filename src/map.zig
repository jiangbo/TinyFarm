const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("component.zig");
const factory = @import("factory.zig");
const loader = @import("map/loader.zig");
const storage = @import("storage.zig");
const Clock = @import("resource/Clock.zig");
const Map = @import("resource/Map.zig");

const tiled = zhu.extend.tiled;
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

const maps = tiled.bind(@import("zon/tileSet.zon"), &.{
    @import("zon/maps/school.zon"),
    @import("zon/maps/town.zon"),
    @import("zon/maps/home_exterior.zon"),
    @import("zon/maps/home_interior.zon"),
});

var loaded: loader.Loaded = .{};
var states: std.EnumArray(Id, SaveMap) = .initFill(.{});

pub fn deinit(gpa: std.mem.Allocator, world: *const World) void {
    if (loaded.loaded) exit(gpa, world);
    for (std.enums.values(Id)) |id| {
        gpa.free(states.get(id).tiles);
    }
}

pub fn enter(gpa: std.mem.Allocator, world: *World, id: Id) void {
    load(gpa, world, maps[@backingInt(id)]);
    const current = world.getResourcePtr(Map).?;
    current.id = id;
    current.props.outdoor = switch (id) {
        .town, .home_exterior => true,
        .school, .home_interior => false,
    };
    restoreCurrent(gpa, world);

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

pub fn exit(gpa: std.mem.Allocator, world: *const World) void {
    saveCurrent(gpa, world);
    unload(gpa, world);
}

pub fn load(gpa: std.mem.Allocator, world: *World, mapData: tiled.Map) void {
    world.addResource(Map.init(gpa, mapData.grid));
    zhu.camera.bound = mapData.grid.size();
    loaded = loader.load(gpa, world, mapData, world.getResourcePtr(Map).?);
}

pub fn unload(gpa: std.mem.Allocator, world: *const World) void {
    loaded.deinit(gpa);
    world.getResourcePtr(Map).?.deinit(gpa);
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

pub fn hoe(current: *Map, position: zhu.Vector2) bool {
    const index = current.grid.worldToIndex(position) orelse return false;
    const tile = &current.tiles[index];
    if (tile.ground != null or tile.object != null) return false;
    const marks = tile.marks;
    if (!marks.contains(.arable)) return false;
    if (marks.contains(.water)) return false;
    if (marks.contains(.occupied)) return false;
    const body: zhu.Shape = .{ .rect = current.grid.indexToRect(index) };
    if (loaded.collision.overlaps(body)) return false;
    tile.ground = .dry;
    return true;
}

pub fn collision() *const spatial.Static {
    return &loaded.collision;
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

fn restoreCurrent(gpa: std.mem.Allocator, world: *World) void {
    const day = world.getResourcePtr(Clock).?.*.day;
    const current = world.getResourcePtr(Map).?;
    const state = ensure(gpa, current.id, current.tiles.len, day);
    advanceState(state, day);

    for (state.tiles, 0..) |saved, index| {
        const tile = &current.tiles[index];
        tile.ground = saved.ground;

        const object = saved.object orelse continue;
        restoreObject(world, index, object);
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
    const mapData = &maps[@backingInt(id)];
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

fn restoreObject(world: *World, index: usize, data: Object) void {
    const current = world.getResourcePtr(Map).?;
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
        for (loaded.solidAreas(range)) |*area| area.* = .init(.zero, .zero);
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

test "当前地图和离线地图跨天推进规则一致" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    world.addResource(Map.init(gpa, maps[0].grid));
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
    world.addResource(Map.init(gpa, maps[0].grid));
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

    restoreObject(&world, 0, .{ .chest = .{ .opened = true } });

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
    world.addResource(Map.init(gpa, maps[0].grid));
    const current = world.getResourcePtr(Map).?;
    defer current.deinit(gpa);

    const entity = world.createEntity();
    world.add(entity, item.Product{ .drop = .one(.stone), .health = 1 });
    current.tiles[0].object = .{ .kind = .product, .entity = entity };

    restoreObject(&world, 0, .{ .product = 4 });

    const product = world.get(entity, item.Product).?;
    try std.testing.expectEqual(.stone, product.drop.item);
    try std.testing.expectEqual(1, product.drop.count);
    try std.testing.expectEqual(4, product.health);
}

test "恢复已移除的产出对象时只清除它自己的阻挡" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();

    var objects: [2]tiled.Object = @splat(.{
        .id = 1,
        .gid = 0,
        .name = "",
        .type = "",
        .position = .xy(4, 0),
        .size = .xy(4, 16),
        .point = false,
        .properties = &.{},
        .extend = .{},
    });
    objects[1].id = 2;
    objects[1].position.x = 8;
    load(gpa, &world, .{ .grid = maps[0].grid, .layers = &.{.{
        .id = 1,
        .name = "collider",
        .image = 0,
        .type = .object,
        .offset = .zero,
        .data = &.{},
        .objects = &objects,
    }} });
    defer unload(gpa, &world);
    const current = world.getResourcePtr(Map).?;

    const entity = world.createEntity();
    world.add(entity, item.Product{ .drop = .one(.stone), .health = 1 });
    current.tiles[0].object = .{ .kind = .product, .entity = entity };
    world.add(entity, component.map.SolidRange{ .start = 0, .count = 1 });

    const productArea: zhu.Shape = .{ .rect = .init(.xy(5, 1), .one) };
    const neighborArea: zhu.Shape = .{ .rect = .init(.xy(9, 1), .one) };
    try std.testing.expect(loaded.collision.overlaps(productArea));
    try std.testing.expect(loaded.collision.overlaps(neighborArea));

    restoreObject(&world, 0, .gone);

    try std.testing.expectEqual(null, current.tiles[0].object);
    try std.testing.expectEqual(.product, current.tiles[0].gone);
    try std.testing.expect(!world.has(entity, item.Product));
    try std.testing.expect(!loaded.collision.overlaps(productArea));
    try std.testing.expect(loaded.collision.overlaps(neighborArea));
}

test "对象层产出对象按碰撞范围占用格子" {
    const imageId = 4321;
    const tileSetId = 8765;

    const treeProps = [_]tiled.Property{
        .{ .name = "obj_type", .value = .{ .string = "tree" } },
        .{ .name = "anim_id", .value = .{ .string = "axe" } },
    };
    const collisionObjects = [_]tiled.Object{.{
        .id = 1,
        .gid = 0,
        .name = "",
        .type = "",
        .position = .xy(16, 0),
        .size = .xy(16, 16),
        .point = false,
        .properties = &.{},
        .extend = .{},
    }};
    const objectGroup = tiled.ObjectGroup{
        .visible = true,
        .objects = &collisionObjects,
    };
    const tiles = [_]tiled.Tile{.{
        .id = 0,
        .objectGroup = objectGroup,
        .properties = &treeProps,
        .animation = &.{},
    }};
    const testTileSets = [_]tiled.TileSet{.{
        .id = tileSetId,
        .columns = 1,
        .tileCount = 1,
        .image = imageId,
        .tileSize = .xy(16, 16),
        .tiles = &tiles,
    }};
    const objects = [_]tiled.Object{.{
        .id = 1,
        .gid = 0x01000000,
        .name = "",
        .type = "",
        .position = .xy(0, 16),
        .size = .xy(32, 16),
        .point = false,
        .properties = &.{},
        .extend = .{},
    }};
    const layers = [_]tiled.Layer{.{
        .id = 1,
        .name = "main",
        .image = 0,
        .type = .object,
        .width = 0,
        .height = 0,
        .offset = .zero,
        .data = &.{},
        .objects = &objects,
    }};
    const testMap = tiled.Map{
        .grid = .{ .width = 3, .height = 1, .cellSide = 16 },
        .layers = &layers,
        .tileSets = &testTileSets,
    };

    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    world.addResource(Map.init(std.testing.allocator, testMap.grid));
    const current = world.getResourcePtr(Map).?;
    defer current.deinit(std.testing.allocator);
    loaded = loader.load(std.testing.allocator, &world, testMap, current);
    defer loaded.deinit(std.testing.allocator);

    current.tiles[0].marks.insert(.arable);
    current.tiles[1].marks.insert(.arable);

    const product = current.tiles[1].get(.product).?;
    try std.testing.expectEqual(null, current.tiles[0].object);
    try std.testing.expect(hoe(current, .xy(8, 8)));
    try std.testing.expect(!hoe(current, .xy(24, 8)));

    clearProduct(&world, testMap.grid.indexToWorld(1));

    try std.testing.expectEqual(null, current.tiles[0].object);
    try std.testing.expectEqual(null, current.tiles[1].object);
    try std.testing.expectEqual(.none, current.tiles[0].gone);
    try std.testing.expectEqual(.product, current.tiles[1].gone);
    try std.testing.expect(!world.has(product, item.Product));
}

test "锄地要求可耕作且没有地图阻挡语义" {
    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();
    const grid: spatial.Grid = .{ .width = 10, .height = 12, .cellSide = 16 };
    load(gpa, &world, .{ .grid = grid });
    defer unload(gpa, &world);
    const current = world.getResourcePtr(Map).?;

    const position = zhu.Vector2.xy(24, 40);
    const index = grid.worldToIndex(position).?;

    try std.testing.expect(!hoe(current, position));

    const tile = &current.tiles[index];
    tile.marks.insert(.arable);
    try std.testing.expect(hoe(current, position));
    try std.testing.expectEqual(.dry, tile.ground);
    try std.testing.expect(!hoe(current, position));
    tile.ground = null;

    tile.set(.crop, world.createEntity());
    try std.testing.expect(!hoe(current, position));
    try std.testing.expectEqual(null, tile.ground);
    tile.object = null;

    tile.marks.insert(.water);
    try std.testing.expect(!hoe(current, position));
    tile.marks.remove(.water);

    tile.marks.insert(.occupied);
    try std.testing.expect(!hoe(current, position));
    tile.marks.remove(.occupied);

    loaded.collision.setCellsInRect(grid.indexToRect(index));
    try std.testing.expect(!hoe(current, position));
}
