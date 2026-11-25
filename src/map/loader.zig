const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("../component.zig");
const factory = @import("../factory.zig");
const Land = @import("Land.zig");

const tiled = zhu.extend.tiled;
const spatial = zhu.extend.spatial;
const World = ecs.World;
const Position = component.Position;
const actor = component.actor;
const item = component.item;
const motion = component.motion;
const Trigger = component.map.Trigger;
const SolidRange = component.map.SolidRange;
const mock: []const tiled.Map = @import("../zon/maps/mock.zon");

const AnimatedTile = struct { vertex: usize, animation: zhu.Animation };

pub const Loaded = struct {
    land: Land = .{},
    collision: spatial.Static = .{},
    areas: std.ArrayList(zhu.Rect) = .empty,
    vertexes: std.ArrayList(zhu.Vertex) = .empty,
    animatedTiles: std.ArrayList(AnimatedTile) = .empty,
    frontStart: usize = 0,
    loaded: bool = false,

    pub fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
        if (!self.loaded) return;
        self.land.deinit(gpa);
        self.collision.deinit(gpa);
        self.areas.clearAndFree(gpa);
        self.vertexes.clearAndFree(gpa);
        self.animatedTiles.clearAndFree(gpa);
        self.frontStart = 0;
        self.loaded = false;
    }

    fn addSolidRect(self: *Loaded, gpa: std.mem.Allocator, rect: zhu.Rect) void {
        std.debug.assert(rect.size.x > 0 and rect.size.y > 0);
        self.areas.append(gpa, rect) catch zhu.oom();
    }

    // SolidRange 只记录对象加入 areas 时的起点和数量。
    pub fn solidAreas(self: Loaded, range: SolidRange) []zhu.Rect {
        return self.areas.items[range.start..][0..range.count];
    }
};

const Context = struct {
    gpa: std.mem.Allocator,
    map: tiled.Map,
    world: *World,
    loaded: *Loaded,
};

pub fn load(gpa: std.mem.Allocator, world: *World, map: tiled.Map) Loaded {
    const grid = map.grid;
    var result: Loaded = .{ .land = Land.init(gpa, grid) };
    result.collision.mask = spatial.SolidMask.init(gpa, .{
        .width = grid.width * 2,
        .height = grid.height * 2,
        .cellSide = @divExact(grid.cellSide, 2),
    }) catch zhu.oom();

    var ctx = Context{
        .gpa = gpa,
        .map = map,
        .world = world,
        .loaded = &result,
    };
    parseLayers(&ctx);
    // 建表后不再追加矩形，销毁物件只需将对应矩形置空。
    const index = spatial.StaticIndex.build(gpa, grid, result.areas.items);
    result.collision.index = index catch zhu.oom();
    result.collision.bounds = .init(.zero, grid.size());
    result.loaded = true;
    return result;
}

fn parseLayers(ctx: *Context) void {
    var foundFrontLayer = false;
    for (ctx.map.layers) |*layer| switch (layer.type) {
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
        ctx.map.grid.width,
        ctx.map.grid.height,
        ctx.loaded.vertexes.items.len,
    });
}

fn parseSolidLayer(ctx: *Context, layer: *const tiled.Layer) void {
    const collision = &ctx.loaded.collision;
    for (layer.data, 0..) |gid, index| {
        if (gid != 0) collision.setCellsInRect(ctx.map.grid.indexToRect(index));
    }
}

fn parseTileLayer(ctx: *Context, layer: *const tiled.Layer) void {
    const rockLayer = layer.isNamed("rock");
    for (layer.data, 0..) |globalId, index| {
        if (globalId == 0) continue; // 0 表示空瓦片，跳过

        if (rockLayer) {
            loadRockTile(ctx, globalId, index);
            continue;
        }
        if (ctx.map.getImage(globalId)) |image| {
            const position = ctx.map.grid.indexToWorld(index);
            if (ctx.map.getAnimation(globalId)) |animation| {
                ctx.loaded.animatedTiles.append(ctx.gpa, .{
                    .vertex = ctx.loaded.vertexes.items.len,
                    .animation = animation,
                }) catch zhu.oom();
                appendVertex(ctx, position, animation.subImage());
            } else appendVertex(ctx, position, image);
        }

        const tile = ctx.map.getTile(globalId) orelse continue;
        if (tile.getProperty("tile_flag", []const u8)) |flag| {
            loadFlags(ctx, index, flag);
        }
    }
}

fn loadRockTile(ctx: *Context, globalId: u32, index: usize) void {
    const entity = factory.spawnMapTile(ctx.world, //
        ctx.map, globalId, index);
    if (!ctx.world.has(entity, item.Product)) return;

    const start = ctx.loaded.areas.items.len;
    ctx.loaded.addSolidRect(ctx.gpa, ctx.map.grid.indexToRect(index));
    ctx.world.add(entity, SolidRange{ .start = start, .count = 1 });
    ctx.loaded.land.tiles[index].set(.product, entity);
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

fn loadFlags(ctx: *Context, index: usize, flags: []const u8) void {
    const tile = ctx.map.grid.indexToRect(index);
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
                ctx.loaded.land.tiles[index].marks.insert(switch (flag) {
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

fn parseImageLayer(ctx: *Context, layer: *const tiled.Layer) void {
    const image = zhu.assets.getImage(layer.image).?
        .sub(.init(.zero, .xy(layer.width, layer.height)));
    appendVertex(ctx, layer.offset, image);
}

fn parseObjectLayer(ctx: *Context, layer: *const tiled.Layer) void {
    if (layer.isNamed("collider")) {
        for (layer.objects) |object| {
            ctx.loaded.addSolidRect(ctx.gpa, object.rect());
        }
        return;
    }

    for (layer.objects) |object| loadObject(ctx, object);
}

fn loadObject(ctx: *Context, object: tiled.Object) void {
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

fn loadActor(ctx: *Context, object: tiled.Object) void {
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

fn loadAnimal(ctx: *Context, object: tiled.Object) void {
    // animal 是没有 gid 的 Tiled 点对象，name 直接对应 AnimalEnum。
    const kind = zhu.enums.to(actor.AnimalEnum, object.name);
    const entity = factory.spawnAnimal(ctx.world, kind);
    // Tiled 点对象的位置就是动物脚底点，和玩家、YSort 使用同一套坐标。
    ctx.world.add(entity, object.position);
    ctx.world.getPtr(entity, actor.Wander).?.home = object.position;
}

fn loadTrigger(ctx: *Context, object: tiled.Object) void {
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

fn loadRest(ctx: *Context, object: tiled.Object) void {
    const entity = ctx.world.createEntity();
    ctx.world.add(entity, object.position);
    ctx.world.add(entity, component.actor.Interact{});
    ctx.world.add(entity, component.map.Rest{});
    ctx.world.add(entity, motion.Shape{
        .rect = object.rect().move(object.position.neg()),
    });
}

fn loadProp(ctx: *Context, object: tiled.Object) void {
    const entity = factory.spawnMapObject(ctx.world, ctx.map, object);
    const solid = addSolidObject(ctx, object);
    if (ctx.world.has(entity, item.Chest)) {
        const rect = object.rect();
        const position = ctx.world.get(entity, Position).?;
        ctx.world.add(entity, motion.Shape{
            .rect = rect.move(position.neg()),
        });

        const tile = ctx.loaded.land.getTile(rect.center()).?;
        tile.object = .{ .kind = .chest, .entity = entity };
    }
    if (ctx.world.has(entity, item.Product)) {
        if (solid.count != 0) {
            // 树这类对象按碰撞范围登记，不按更大的显示范围登记。
            for (ctx.loaded.solidAreas(solid)) |area| {
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

fn addSolidObject(ctx: *Context, object: tiled.Object) SolidRange {
    const start = ctx.loaded.areas.items.len;
    const tile = ctx.map.getTile(object.gid) orelse
        return .{ .start = start, .count = 0 };
    const group = tile.objectGroup orelse
        return .{ .start = start, .count = 0 };
    const topLeft = object.topLeft();

    for (group.objects) |local| {
        const position = topLeft.add(local.position);
        ctx.loaded.addSolidRect(
            ctx.gpa,
            zhu.Rect.init(position, local.size),
        );
    }
    return .{
        .start = start,
        .count = ctx.loaded.areas.items.len - start,
    };
}

fn loadLight(ctx: *Context, object: tiled.Object) void {
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

fn appendVertex(ctx: *Context, position: zhu.Vector2, image: zhu.Image) void {
    ctx.loaded.vertexes.append(ctx.gpa, .{
        .position = position,
        .layer = image.layer,
        .size = image.size,
        .uvRect = image.uvRect(),
    }) catch zhu.oom();
}

// 对象层产出按碰撞范围登记；没有碰撞范围时退回到传入矩形。
fn setProductTiles(ctx: *Context, entity: ecs.Entity, rect: zhu.Rect) void {
    var iter = ctx.map.grid.indicesInRect(rect);
    while (iter.next()) |index| {
        ctx.loaded.land.tiles[index].set(.product, entity);
    }
}

test "actor 点对象会生成 NPC，player 点对象只保留标记" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    var loaded = load(std.testing.allocator, &world, mock[0]);
    defer loaded.deinit(std.testing.allocator);

    var query = world.query(.{
        Position,
        actor.Npc,
        actor.Interact,
        actor.Wander,
        actor.Dialog,
    });
    const row = query.next().?;
    const position = row.get(Position);
    const wander = row.get(actor.Wander);
    const dialog = row.get(actor.Dialog);

    try std.testing.expectEqual(95, position.x);
    try std.testing.expectEqual(274, position.y);
    try std.testing.expectEqual(95, wander.home.x);
    try std.testing.expectEqual(274, wander.home.y);
    try std.testing.expect(dialog.lines.len != 0);
    try std.testing.expectEqual(null, query.next());
}

test "trigger 对象会创建 ECS 触发器实体" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    var loaded = load(std.testing.allocator, &world, mock[1]);
    defer loaded.deinit(std.testing.allocator);

    var query = world.query(.{component.map.Trigger});
    const row = query.next().?;
    const trigger = row.get(component.map.Trigger);

    try std.testing.expectEqual(2, trigger.selfId);
    try std.testing.expectEqual(3, trigger.targetId);
    try std.testing.expectEqual(component.map.Id.school, trigger.targetMap);
    try std.testing.expectEqual(.bottom, trigger.startOffset);
    try std.testing.expectEqual(10, trigger.rect.min.x);
    try std.testing.expectEqual(20, trigger.rect.min.y);
    try std.testing.expectEqual(null, query.next());
}

test "rest 对象会创建可交互实体" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    var loaded = load(std.testing.allocator, &world, mock[2]);
    defer loaded.deinit(std.testing.allocator);

    var query = world.query(.{
        Position,
        actor.Interact,
        component.map.Rest,
        motion.Shape,
    });
    const row = query.next().?;
    const shape = row.get(motion.Shape);

    try std.testing.expectEqual(10, row.get(Position).x);
    try std.testing.expectEqual(20, row.get(Position).y);
    try std.testing.expectEqual(30, shape.rect.size.x);
    try std.testing.expectEqual(40, shape.rect.size.y);
    try std.testing.expectEqual(null, query.next());
}

test "加载地图产出对象会按对象和 rock 图层写入目标格" {
    const imageId = 1234;
    const tileSetId = 5678;

    const treeProps = [_]tiled.Property{
        .{ .name = "obj_type", .value = .{ .string = "tree" } },
        .{ .name = "anim_id", .value = .{ .string = "axe" } },
    };
    const rockProps = [_]tiled.Property{
        .{ .name = "anim_id", .value = .{ .string = "pickaxe" } },
        .{ .name = "tile_flag", .value = .{ .string = "SOLID" } },
    };
    const tiles = [_]tiled.Tile{
        .{
            .id = 0,
            .objectGroup = null,
            .properties = &treeProps,
            .animation = &.{},
        },
        .{
            .id = 1,
            .objectGroup = null,
            .properties = &rockProps,
            .animation = &.{},
        },
    };
    const testTileSets = [_]tiled.TileSet{.{
        .id = tileSetId,
        .columns = 3,
        .tileCount = 3,
        .image = imageId,
        .tileSize = .xy(16, 16),
        .tiles = &tiles,
    }};
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();

    var testMap = mock[3];
    testMap.tileSets = &testTileSets;
    var loaded = load(std.testing.allocator, &world, testMap);
    defer loaded.deinit(std.testing.allocator);

    const tree = loaded.land.tiles[0].object.?;
    const rock = loaded.land.tiles[1].object.?;
    const treeProd = world.get(tree.entity, item.Product).?;
    const rockProd = world.get(rock.entity, item.Product).?;
    const treeCfg = factory.itemConfig(.timber);
    const rockCfg = factory.itemConfig(.stone);

    try std.testing.expectEqual(.product, tree.kind);
    try std.testing.expectEqual(.none, loaded.land.tiles[0].gone);
    try std.testing.expectEqual(.timber, treeProd.drop.item);
    try std.testing.expectEqual(treeCfg.health.?, treeProd.health);
    try std.testing.expectEqual(.product, rock.kind);
    try std.testing.expectEqual(.none, loaded.land.tiles[1].gone);
    try std.testing.expectEqual(.stone, rockProd.drop.item);
    try std.testing.expectEqual(rockCfg.health.?, rockProd.health);
    try std.testing.expectEqual(null, loaded.land.tiles[2].object);
    const range = world.get(rock.entity, SolidRange).?;
    const rect = testMap.grid.indexToRect(1);
    try std.testing.expectEqualSlices(zhu.Rect, &.{rect}, loaded.solidAreas(range));
}
