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
const Trigger = component.map.Trigger;
const SolidRange = component.map.SolidRange;

const Context = struct {
    gpa: std.mem.Allocator,
    map: tiled.Map,
    world: *World,
    current: *Map,
};

pub fn load(gpa: std.mem.Allocator, world: *World, map: tiled.Map, out: *Map) void {
    const grid = map.grid;
    if (map.getClass("ambient")) |ambient| {
        out.props.indoorAmbient = .fromFloat(.{
            .r = ambient.get("red", f32) orelse 1,
            .g = ambient.get("green", f32) orelse 1,
            .b = ambient.get("blue", f32) orelse 1,
            .a = 1,
        });
    }
    out.collision.mask = spatial.SolidMask.init(gpa, .{
        .width = grid.width * 2,
        .height = grid.height * 2,
        .cellSide = @divExact(grid.cellSide, 2),
    }) catch zhu.oom();

    var ctx = Context{
        .gpa = gpa,
        .map = map,
        .world = world,
        .current = out,
    };
    parseLayers(&ctx);
    // 建表后不再追加矩形，销毁物件只需将对应矩形置空。
    const index = spatial.StaticIndex.build(gpa, grid, out.areas.items);
    out.collision.index = index catch zhu.oom();
    out.collision.bounds = .init(.zero, grid.size());
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
                const start = ctx.current.vertexes.items.len;
                ctx.current.frontStart = start;
                foundFrontLayer = true;
            }
            parseObjectLayer(ctx, layer);
        },
    };

    if (!foundFrontLayer) {
        ctx.current.frontStart = ctx.current.vertexes.items.len;
    }

    std.log.info("map loaded: {}x{}, tiles: {}", .{
        ctx.map.grid.width,
        ctx.map.grid.height,
        ctx.current.vertexes.items.len,
    });
}

fn parseSolidLayer(ctx: *Context, layer: *const tiled.Layer) void {
    const collision = &ctx.current.collision;
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
                ctx.current.animatedTiles.append(ctx.gpa, .{
                    .vertex = ctx.current.vertexes.items.len,
                    .animation = animation,
                }) catch zhu.oom();
                addImage(ctx, position, animation.subImage());
            } else addImage(ctx, position, image);
        }

        const tile = ctx.map.getTile(globalId) orelse continue;
        if (tile.getProperty("tile_flag", []const u8)) |flag| {
            loadFlags(ctx, index, flag);
        }
    }
}

fn loadRockTile(ctx: *Context, globalId: u32, index: usize) void {
    const rect = ctx.current.grid.indexToRect(index);
    const entity = factory.spawnMapTile(ctx.world, ctx.map, globalId, rect);
    if (!ctx.world.has(entity, item.Product)) return;

    const start = ctx.current.areas.items.len;
    addSolidRect(ctx, rect);
    ctx.world.add(entity, SolidRange{ .start = start, .count = 1 });
    ctx.current.tiles[index].set(.product, entity);
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
                ctx.current.tiles[index].marks.insert(switch (flag) {
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
        ctx.current.collision.setCellsInRect(rect);
    }
}

fn parseImageLayer(ctx: *Context, layer: *const tiled.Layer) void {
    const image = zhu.assets.getImage(layer.image).?
        .sub(.init(.zero, .xy(layer.width, layer.height)));
    addImage(ctx, layer.offset, image);
}

fn addImage(ctx: *Context, position: zhu.Vector2, image: zhu.Image) void {
    ctx.current.vertexes.append(ctx.gpa, .{
        .position = position,
        .layer = image.layer,
        .size = image.size,
        .uvRect = image.uvRect(),
    }) catch zhu.oom();
}

fn parseObjectLayer(ctx: *Context, layer: *const tiled.Layer) void {
    if (layer.isNamed("collider")) {
        for (layer.objects) |object| {
            addSolidRect(ctx, object.rect());
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

        const tile = ctx.current.getTile(rect.center()).?;
        tile.object = .{ .kind = .chest, .entity = entity };
    }
    if (ctx.world.has(entity, item.Product)) {
        if (solid.count != 0) {
            // 树这类对象按碰撞范围登记，不按更大的显示范围登记。
            for (ctx.current.solidAreas(solid)) |area| {
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

fn addSolidRect(ctx: *Context, rect: zhu.Rect) void {
    std.debug.assert(rect.size.x > 0 and rect.size.y > 0);
    ctx.current.areas.append(ctx.gpa, rect) catch zhu.oom();
}

fn addSolidObject(ctx: *Context, object: tiled.Object) SolidRange {
    const start = ctx.current.areas.items.len;
    const tile = ctx.map.getTile(object.gid) orelse
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
        .count = ctx.current.areas.items.len - start,
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

// 对象层产出按碰撞范围登记；没有碰撞范围时退回到传入矩形。
fn setProductTiles(ctx: *Context, entity: ecs.Entity, rect: zhu.Rect) void {
    var iter = ctx.map.grid.indicesInRect(rect);
    while (iter.next()) |index| {
        ctx.current.tiles[index].set(.product, entity);
    }
}
