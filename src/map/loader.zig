const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("../component.zig");
const factory = @import("../factory.zig");
const Map = @import("../resource/Map.zig");

const tiled = zhu.extend.tiled;
const spatial = zhu.extend.spatial;
const World = ecs.World;
const Position = component.Position;
const actor = component.actor;
const item = component.item;
const motion = component.motion;
const Id = component.map.Id;
const Trigger = component.map.Trigger;
const SolidRange = component.map.SolidRange;

const maps = tiled.bind(@import("../zon/tileSet.zon"), &.{
    @import("../zon/maps/school.zon"),
    @import("../zon/maps/town.zon"),
    @import("../zon/maps/home_exterior.zon"),
    @import("../zon/maps/home_interior.zon"),
});

pub fn definition(id: Id) *const tiled.Map {
    return &maps[@backingInt(id)];
}

const Context = struct {
    gpa: std.mem.Allocator,
    world: *World,
    source: *const tiled.Map,
    loaded: *Map,
};

pub fn load(gpa: std.mem.Allocator, world: *World, id: Id) Map {
    const map = definition(id);
    const grid = map.grid;
    var loaded = Map.init(gpa, id, grid);
    loaded.props.outdoor = switch (id) {
        .town, .home_exterior => true,
        .school, .home_interior => false,
    };
    if (!loaded.props.outdoor) {
        if (map.getClass("ambient")) |ambient| {
            loaded.props.indoorAmbient = .fromFloat(.{
                .r = ambient.get("red", f32) orelse 1,
                .g = ambient.get("green", f32) orelse 1,
                .b = ambient.get("blue", f32) orelse 1,
                .a = 1,
            });
        }
    }
    loaded.collision.mask = spatial.SolidMask.init(gpa, .{
        .width = grid.width * 2,
        .height = grid.height * 2,
        .cellSide = @divExact(grid.cellSide, 2),
    }) catch zhu.oom();

    parseLayers(&.{ .gpa = gpa, .world = world, .source = map, .loaded = &loaded });
    // 建表后不再追加矩形，销毁物件只需将对应矩形置空。
    const index = spatial.StaticIndex.build(gpa, grid, loaded.areas.items);
    loaded.collision.index = index catch zhu.oom();
    loaded.collision.bounds = .init(.zero, grid.size());
    return loaded;
}

fn parseLayers(ctx: *const Context) void {
    var foundFrontLayer = false;
    for (ctx.source.layers) |*layer| switch (layer.type) {
        .tile => if (layer.isNamed("solid")) {
            parseSolidLayer(ctx, layer);
        } else parseTileLayer(ctx, layer),
        .image => parseImageLayer(ctx, layer),
        .object => {
            if (!foundFrontLayer and layer.isNamed("main")) {
                const start = ctx.loaded.vertexes.items.len;
                ctx.loaded.frontStart = start;
                foundFrontLayer = true;
            }
            parseObjectLayer(ctx, layer);
        },
    };

    if (!foundFrontLayer) {
        ctx.loaded.frontStart = ctx.loaded.vertexes.items.len;
    }

    std.log.info("map loaded: {}x{}, tiles: {}", .{
        ctx.loaded.grid.width,
        ctx.loaded.grid.height,
        ctx.loaded.vertexes.items.len,
    });
}

fn parseSolidLayer(ctx: *const Context, layer: *const tiled.Layer) void {
    const collision = &ctx.loaded.collision;
    const grid = ctx.loaded.grid;
    for (layer.data, 0..) |gid, index| {
        if (gid != 0) collision.setCellsInRect(grid.indexToRect(index));
    }
}

fn parseTileLayer(ctx: *const Context, layer: *const tiled.Layer) void {
    const map = ctx.source;
    const rockLayer = layer.isNamed("rock");
    for (layer.data, 0..) |globalId, index| {
        if (globalId == 0) continue; // 0 表示空瓦片，跳过

        if (rockLayer) {
            loadRockTile(ctx, globalId, index);
            continue;
        }
        if (map.getImage(globalId)) |image| {
            const position = ctx.loaded.grid.indexToWorld(index);
            if (map.getAnimation(globalId)) |animation| {
                ctx.loaded.animatedTiles.append(ctx.gpa, .{
                    .vertex = ctx.loaded.vertexes.items.len,
                    .animation = animation,
                }) catch zhu.oom();
                addImage(ctx, position, animation.subImage());
            } else addImage(ctx, position, image);
        }

        const tile = map.getTile(globalId) orelse continue;
        if (tile.getProperty("tile_flag", []const u8)) |flag| {
            loadFlags(ctx, index, flag);
        }
    }
}

fn loadRockTile(ctx: *const Context, globalId: u32, index: usize) void {
    const rect = ctx.loaded.grid.indexToRect(index);
    const entity = factory.spawnMapTile(ctx.world, ctx.source.*, globalId, rect);
    if (!ctx.world.has(entity, item.Product)) return;

    const start = ctx.loaded.areas.items.len;
    addSolidRect(ctx, rect);
    ctx.world.add(entity, SolidRange{ .start = start, .count = 1 });
    ctx.loaded.tiles[index].set(.product, entity);
}

const TileFlag = enum {
    SOLID,
    BLOCK_N,
    BLOCK_S,
    BLOCK_W,
    BLOCK_E,
    HAZARD,
    WATER,
    INTERACT,
    ARABLE,
    OCCUPIED,
};

fn loadFlags(ctx: *const Context, index: usize, flags: []const u8) void {
    const tile = ctx.loaded.grid.indexToRect(index);
    const half = tile.size.x * 0.5;
    var iter = std.mem.tokenizeScalar(u8, flags, ',');
    while (iter.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t\r\n");
        const flag = std.meta.stringToEnum(TileFlag, token) orelse
            std.debug.panic("unknown tile_flag token: {s}", .{token});
        const rect: zhu.Rect = switch (flag) {
            .SOLID => tile,
            .BLOCK_N => .init(tile.min, .xy(tile.size.x, half)),
            .BLOCK_S => .init(tile.min.addY(half), .xy(tile.size.x, half)),
            .BLOCK_W => .init(tile.min, .xy(half, tile.size.y)),
            .BLOCK_E => .init(tile.min.addX(half), .xy(half, tile.size.y)),
            else => {
                ctx.loaded.tiles[index].marks.insert(switch (flag) {
                    .HAZARD => .hazard,
                    .WATER => .water,
                    .INTERACT => .interact,
                    .ARABLE => .arable,
                    .OCCUPIED => .occupied,
                    else => unreachable,
                });
                continue;
            },
        };
        ctx.loaded.collision.setCellsInRect(rect);
    }
}

fn parseImageLayer(ctx: *const Context, layer: *const tiled.Layer) void {
    const image = zhu.assets.getImage(layer.image).?
        .sub(.init(.zero, .xy(layer.width, layer.height)));
    addImage(ctx, layer.offset, image);
}

fn addImage(ctx: *const Context, position: zhu.Vector2, image: zhu.Image) void {
    ctx.loaded.vertexes.append(ctx.gpa, .{
        .position = position,
        .layer = image.layer,
        .size = image.size,
        .uvRect = image.uvRect(),
    }) catch zhu.oom();
}

fn parseObjectLayer(ctx: *const Context, layer: *const tiled.Layer) void {
    if (layer.isNamed("collider")) {
        for (layer.objects) |object| {
            addSolidRect(ctx, object.rect());
        }
        return;
    }

    for (layer.objects) |object| loadObject(ctx, object);
}

fn loadObject(ctx: *const Context, object: tiled.Object) void {
    if (object.point and object.isType("actor")) {
        return loadActor(ctx, object);
    }
    if (object.point and object.isType("animal")) {
        return loadAnimal(ctx, object);
    }
    if (object.isType("map_trigger")) {
        return loadTrigger(ctx, object);
    }
    if (object.isType("rest")) return loadRest(ctx, object);
    if (object.isType("light")) return loadLight(ctx, object);
    if (object.gid != 0) return loadProp(ctx, object);
}

fn loadActor(ctx: *const Context, object: tiled.Object) void {
    // player 由 scene 统一创建，地图中的点只作为 Tiled 标记保留。
    if (object.isNamed("player")) return;

    if (object.isNamed("friend")) {
        const entity = factory.spawnFriend(ctx.world);
        // Tiled 点对象的位置就是 NPC 脚底点，和 YSort 使用同一套坐标。
        ctx.world.add(entity, object.position);
        ctx.world.getPtr(entity, actor.Wander).?.home = object.position;
        return;
    }
    std.debug.panic("unknown actor object: {s}", .{object.name});
}

fn loadAnimal(ctx: *const Context, object: tiled.Object) void {
    // animal 是没有 gid 的 Tiled 点对象，name 直接对应 AnimalEnum。
    const kind = zhu.enums.to(actor.AnimalEnum, object.name);
    const entity = factory.spawnAnimal(ctx.world, kind);
    // Tiled 点对象的位置就是动物脚底点，和玩家、YSort 使用同一套坐标。
    ctx.world.add(entity, object.position);
    ctx.world.getPtr(entity, actor.Wander).?.home = object.position;
}

fn loadTrigger(ctx: *const Context, object: tiled.Object) void {
    std.debug.assert(object.size.x > 0 and object.size.y > 0);

    const target = object.getProperty("target_map", []const u8).?;
    const start = object.getProperty("start_offset", []const u8).?;
    const startOffset = std.meta.stringToEnum(
        component.map.StartOffset,
        start,
    );

    const trigger: Trigger = .{
        .rect = object.rect(),
        .selfId = object.getProperty("self_id", i32).?,
        .targetId = object.getProperty("target_id", i32).?,
        .targetMap = zhu.enums.to(component.map.Id, target),
        .startOffset = startOffset orelse .none,
    };
    _ = factory.spawnMapTrigger(ctx.world, trigger);
}

fn loadRest(ctx: *const Context, object: tiled.Object) void {
    const entity = ctx.world.createEntity();
    ctx.world.add(entity, object.position);
    ctx.world.add(entity, component.actor.Interact{});
    ctx.world.add(entity, component.map.Rest{});
    ctx.world.add(entity, motion.Shape{
        .rect = object.rect().move(object.position.neg()),
    });
}

fn loadProp(ctx: *const Context, object: tiled.Object) void {
    const entity = factory.spawnMapObject(ctx.world, ctx.source.*, object);
    const solid = addSolidObject(ctx, object);
    if (ctx.world.has(entity, item.Chest)) {
        const rect = object.rect();
        const position = ctx.world.get(entity, Position).?;
        ctx.world.add(entity, motion.Shape{
            .rect = rect.move(position.neg()),
        });

        const tile = ctx.loaded.getTile(rect.center()).?;
        tile.object = .{ .kind = .chest, .entity = entity };
    }
    if (ctx.world.has(entity, item.Product)) {
        if (solid.count != 0) {
            // 树这类对象按碰撞范围登记，不按更大的显示范围登记。
            const areas = ctx.loaded.areas.items[solid.start..][0..solid.count];
            for (areas) |area| {
                setProductTiles(ctx, entity, area);
            }
        } else {
            setProductTiles(ctx, entity, object.rect());
        }
    }
    if (solid.count != 0) {
        ctx.world.add(entity, solid);
    }
}

fn addSolidRect(ctx: *const Context, rect: zhu.Rect) void {
    std.debug.assert(rect.size.x > 0 and rect.size.y > 0);
    ctx.loaded.areas.append(ctx.gpa, rect) catch zhu.oom();
}

fn addSolidObject(ctx: *const Context, object: tiled.Object) SolidRange {
    const start = ctx.loaded.areas.items.len;
    const tile = ctx.source.getTile(object.gid) orelse
        return .{ .start = start, .count = 0 };
    const group = tile.objectGroup orelse
        return .{ .start = start, .count = 0 };
    const topLeft = object.topLeft();

    for (group.objects) |local| {
        const position = topLeft.add(local.position);
        addSolidRect(ctx, .init(position, local.size));
    }
    return .{
        .start = start,
        .count = ctx.loaded.areas.items.len - start,
    };
}

fn loadLight(ctx: *const Context, object: tiled.Object) void {
    if (object.isNamed("point")) {
        _ = factory.spawnPointLight(ctx.world, object);
        return;
    }

    if (object.isNamed("spot")) {
        _ = factory.spawnSpotLight(ctx.world, object);
        return;
    }

    if (object.isNamed("emissive")) {
        _ = factory.spawnEmissiveLight(ctx.world, object);
    }
}

// 对象层产出按碰撞范围登记；没有碰撞范围时退回到传入矩形。
fn setProductTiles(ctx: *const Context, entity: ecs.Entity, rect: zhu.Rect) void {
    var iter = ctx.loaded.grid.indicesInRect(rect);
    while (iter.next()) |index| {
        ctx.loaded.tiles[index].set(.product, entity);
    }
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
    const data = tiled.Map{
        .grid = .{ .width = 3, .height = 1, .cellSide = 16 },
        .layers = &layers,
        .tileSets = &testTileSets,
    };

    const gpa = std.testing.allocator;
    var world = ecs.World.init(gpa);
    defer world.deinit();

    var current = Map.init(gpa, .school, data.grid);
    defer current.deinit(gpa);
    parseLayers(&.{ .gpa = gpa, .world = &world, .source = &data, .loaded = &current });

    try std.testing.expectEqual(null, current.tiles[0].object);
    try std.testing.expect(current.tiles[1].get(.product) != null);
    try std.testing.expectEqual(null, current.tiles[2].object);
}
