const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("component.zig");

const actor = component.actor;
const farm = component.farm;
const item = component.item;
const light = component.light;
const map = component.map;
const motion = component.motion;
const render = component.render;
const sound = component.sound;
const ui = component.ui;

const World = ecs.World;
const Entity = ecs.Entity;
const tiled = zhu.extend.tiled;
const Object = tiled.Object;

pub const Actor = struct {
    sprite: Sprite,
    rows: [4]i8,
    sources: zhu.graphics.SliceSource(actor.Action),
};

pub const Character = struct {
    sprite: Sprite,
    rows: [4]i8,
    sources: zhu.graphics.SliceSource(actor.Action),
    speed: f32,
    wanderRadius: f32,
    soundId: ?sound.Id = null,
    voice: ?sound.Voice = null,
    name: []const u8,
    dialog: []const []const u8 = &.{},
};

pub const Sprite = struct {
    imageId: zhu.graphics.ImageId,
    rect: zhu.Rect,
    offset: zhu.Vector2 = .zero,
    size: zhu.Vector2,
};

pub const Item = struct {
    name: []const u8,
    category: []const u8,
    description: []const u8,
    limit: u32,
    icon: Sprite,
    product: ?item.Stack = null,
    hit: ?item.Product = null,
};

pub const CropStage = struct { sprite: Sprite, duration: f32 };
const StageFields = zhu.enums.FieldStruct(farm.GrowthEnum, CropStage);
const CropStages = std.EnumArray(farm.GrowthEnum, CropStage);

pub const Config = struct {
    player: Actor,
    playerLight: light.Point,
    items: zhu.enums.FieldStruct(item.ItemEnum, Item),
    animals: zhu.enums.FieldStruct(actor.AnimalEnum, Character),
    friend: Character,
    crops: zhu.enums.FieldStruct(farm.CropEnum, StageFields),
};

const zon: Config = @import("zon/factory.zon");
const items: std.EnumArray(item.ItemEnum, Item) = .init(zon.items);
const animals: std.EnumArray(actor.AnimalEnum, Character) = .init(zon.animals);
const crops = blk: {
    var table: std.EnumArray(farm.CropEnum, CropStages) = .initUndefined();
    for (std.enums.values(farm.CropEnum)) |kind| {
        table.set(kind, .init(@field(zon.crops, @tagName(kind))));
    }
    break :blk table;
};

pub fn itemConfig(itemType: item.ItemEnum) Item {
    return items.get(itemType);
}

// 从 CropEnum 得到对应的种子 ItemEnum
pub fn seedItem(kind: farm.CropEnum) item.ItemEnum {
    return switch (kind) {
        .strawberry => .strawberry_seed,
        .potato => .potato_seed,
    };
}

// 从 CropEnum 得到对应的产出 ItemEnum
pub fn harvestItem(kind: farm.CropEnum) item.ItemEnum {
    return switch (kind) {
        .strawberry => .strawberry,
        .potato => .potato,
    };
}

pub fn cropStage(kind: farm.CropEnum, stage: farm.GrowthEnum) CropStage {
    return crops.get(kind).get(stage);
}

pub fn advanceCropOneDay(crop: *farm.Crop, watered: bool) bool {
    if (crop.stage == .mature) return false;

    crop.next -= if (watered) 2 else 1;
    if (crop.next > 0) return false;

    crop.stage = zhu.enums.next(crop.stage);
    crop.next = cropStage(crop.kind, crop.stage).duration;
    return true;
}

pub fn resolveImage(sprite: Sprite) zhu.graphics.Image {
    return zhu.assets.getImage(sprite.imageId).?.sub(sprite.rect);
}

pub fn spawnPlayer(world: *World, spawn: zhu.Vector2, facing: actor.Facing) void {
    if (world.getIdentity(actor.Player)) |oldPlayer| {
        world.destroyEntity(oldPlayer);
        world.removeIdentity(actor.Player);
    }

    const config = zon.player;

    const player = world.createIdentity(actor.Player);
    world.add(player, spawn);
    world.add(player, motion.Velocity{});
    world.add(player, motion.Shape{
        .circle = .init(.xy(0, -5), 5),
    });
    world.add(player, motion.Blocking{});
    const character: actor.Actor = .{
        .facing = facing,
        .rows = config.rows,
        .sources = .generate(config.sources),
    };
    world.add(player, character);
    const source = character.sources.get(.idle);
    var animation = zhu.Animation.initSource(source);
    animation.row = character.frameRow();

    world.add(player, render.Sprite{
        .image = animation.subImage(),
        .offset = config.sprite.offset,
        .size = config.sprite.size,
        .flip = character.flip(),
    });

    world.add(player, animation);
    world.add(player, render.Render{ .layer = .actor });
    world.add(player, render.YSort{});
    world.add(player, ui.Target{});
    world.add(player, zon.playerLight);
}

pub fn spawnAnimal(world: *World, kind: actor.Animal) Entity {
    const config = animals.get(kind);

    const entity = switch (kind) {
        inline else => |tag| spawnNpc(world, comptime animals.get(tag)),
    };
    world.add(entity, kind);
    const interval = actor.Life.eatInterval;
    world.add(entity, actor.Life{
        .timer = zhu.random.float(interval * 0.5, interval),
    });
    if (config.soundId) |id| world.add(entity, id);
    if (config.voice) |voice| world.add(entity, voice);
    return entity;
}

pub fn spawnFriend(world: *World) Entity {
    return spawnNpc(world, zon.friend);
}

fn spawnNpc(world: *World, comptime config: Character) Entity {
    const entity = world.createEntity();
    world.add(entity, motion.Velocity{});
    world.add(entity, motion.Shape{
        .circle = .init(.xy(0, -5), 5),
    });
    world.add(entity, motion.Blocking{});
    const character: actor.Actor = .{
        .rows = config.rows,
        .sources = .generate(config.sources),
    };
    world.add(entity, character);
    const source = character.sources.get(.idle);
    const animation = zhu.Animation.initSource(source);

    world.add(entity, render.Sprite{
        .image = animation.subImage(),
        .offset = config.sprite.offset,
        .size = config.sprite.size,
    });
    world.add(entity, animation);
    world.add(entity, render.Render{ .layer = .actor });
    world.add(entity, render.YSort{});
    world.add(entity, actor.Npc{});
    world.add(entity, actor.Wander{
        .radius = config.wanderRadius,
        .speed = config.speed,
    });
    if (config.dialog.len != 0) {
        world.add(entity, actor.Interact{});
        world.add(entity, actor.Dialog{ .lines = config.dialog });
    }

    return entity;
}

pub fn spawnMapObject(
    world: *World,
    data: tiled.Map,
    object: Object,
) Entity {
    const entity = world.createEntity();

    var image: zhu.graphics.Image = .empty;
    const tile = data.getTile(object.gid).?;
    if (data.getAnimation(object.gid)) |a| {
        var animation = a;
        image = animation.subImage();
        // anim_id 表示由玩法触发的动画，地图加载时只挂组件不自动播放。
        if (tile.hasProperty("anim_id")) {
            animation.source.loop = false;
            animation.stop();
        }
        world.add(entity, animation);
    } else {
        image = data.getImage(object.gid) orelse .empty;
    }

    const hasSize = object.size.x > 0 and object.size.y > 0;
    const size = if (hasSize) object.size else image.size;
    const drawPosition = object.position.addY(-size.y);
    const sortY = mapObjectSortY(object, tile, size);
    const sortPosition = zhu.Vector2.xy(object.position.x, sortY);

    world.add(entity, sortPosition);
    world.add(entity, render.Sprite{
        .image = image,
        .offset = drawPosition.sub(sortPosition),
        .size = size,
        .flip = object.extend.flipX,
    });
    world.add(entity, render.Render{ .layer = .actor });
    world.add(entity, render.YSort{});

    addMapItemProduct(world, entity, tile);

    // Tiled 转换数据沿用 obj_type，值为 chest 时挂宝箱组件。
    if (tile.getProperty("obj_type", []const u8)) |kind| {
        if (std.mem.eql(u8, kind, "chest")) {
            world.add(entity, actor.Interact{});
            world.add(entity, item.Chest{ .items = chestItems(object) });
        }
    }

    return entity;
}

pub fn spawnMapTile(world: *World, data: tiled.Map, gid: u32, rect: zhu.Rect) Entity {
    const topLeft = rect.min;
    const size = rect.size;
    const position = topLeft.addY(size.y);
    var image = data.getImage(gid) orelse zhu.graphics.Image{ .size = size };
    const entity = world.createEntity();

    if (data.getAnimation(gid)) |baseAnimation| {
        var animation = baseAnimation;
        animation.source.loop = false;
        animation.stop();
        image = animation.subImage();
        world.add(entity, animation);
    }

    // tile layer 没有 Tiled object，统一用瓦片底边作为排序点。
    world.add(entity, position);
    world.add(entity, render.Sprite{
        .image = image,
        .offset = topLeft.sub(position),
        .size = size,
    });
    world.add(entity, render.Render{ .layer = .actor });
    world.add(entity, render.YSort{});

    if (data.getTile(gid)) |tile| {
        addMapItemProduct(world, entity, tile);
    }
    return entity;
}

fn addMapItemProduct(
    world: *World,
    entity: Entity,
    tile: *const tiled.Tile,
) void {
    const animation = tile.getProperty("anim_id", []const u8) orelse return;
    const tool = std.meta.stringToEnum(item.ItemEnum, animation) orelse return;
    const hit = itemConfig(tool).hit orelse return;
    // 工具命中配置提供掉落和生命值，anim_id 只负责选中工具。
    world.add(entity, hit);
}

fn chestItems(object: Object) item.Counts {
    var result = item.Counts.initFill(0);

    for (std.enums.values(item.ItemEnum)) |itemType| {
        const count = object.getProperty(@tagName(itemType), u32);
        result.set(itemType, count orelse continue);
    }
    return result;
}

fn mapObjectSortY(object: Object, tile: *const tiled.Tile, size: zhu.Vector2) f32 {
    const group = tile.objectGroup orelse return object.position.y;
    var result: f32 = 0;
    var found = false;

    for (group.objects) |local| {
        if (local.size.x <= 0 or local.size.y <= 0) continue;

        // Tiled 瓦片对象 position 是图片底边，碰撞框坐标从图片左上角开始。
        const bottom = object.position.y - size.y +
            local.position.y + local.size.y;
        if (!found or bottom > result) {
            result = bottom;
            found = true;
        }
    }

    return if (found) result else object.position.y;
}

pub fn spawnMapTrigger(world: *World, trigger: map.Trigger) Entity {
    const entity = world.createEntity();
    world.add(entity, trigger);
    return entity;
}

pub fn spawnPointLight(world: *World, object: Object) Entity {
    const entity = world.createEntity();
    world.add(entity, light.Point{
        .radius = object.getProperty("radius", f32) orelse 96,
    });
    world.add(entity, object.position);
    applyLight(world, entity, object);
    return entity;
}

pub fn spawnSpotLight(world: *World, object: Object) Entity {
    const entity = world.createEntity();
    const spot = object.getClass("spot").?;
    std.debug.assert(spot.is("Spotlight"));
    world.add(entity, light.Spot{
        .radius = spot.get("radius", f32).?,
        .direction = spotDirection(spot),
    });
    world.add(entity, object.position);
    applyLight(world, entity, object);
    return entity;
}

pub fn spawnEmissiveLight(world: *World, object: Object) Entity {
    const entity = world.createEntity();
    world.add(entity, light.Emissive{
        .size = object.size,
        .intensity = object.getProperty("intensity", f32) orelse 1.0,
    });
    world.add(entity, object.position);
    applyLight(world, entity, object);
    return entity;
}

fn spotDirection(spot: zhu.extend.tiled.ClassProperty) zhu.Vector2 {
    const degrees = spot.get("direction_deg", f32).?;
    const radians = std.math.degreesToRadians(degrees);
    return .xy(@cos(radians), @sin(radians));
}

// 根据 Tiled 属性设置灯光的昼夜可见性
fn applyLight(world: *World, entity: Entity, object: Object) void {
    const day = object.getProperty("day_only", bool) orelse false;
    const night = object.getProperty("night_only", bool) orelse !day;
    world.add(entity, light.Pending{});

    if (day) world.add(entity, light.Day{});

    if (night) world.add(entity, light.Night{});
}

pub fn spawnCrop(world: *World, position: zhu.Vector2, crop: farm.Crop) Entity {
    const sprite, const layer = cropAppearance(crop);
    const entity = world.createEntity();
    world.add(entity, crop);
    world.add(entity, position);
    world.add(entity, sprite);
    world.add(entity, render.Render{ .layer = layer });
    world.add(entity, render.YSort{});
    return entity;
}

pub fn refreshCropSprite(world: *const World, entity: Entity, crop: farm.Crop) void {
    const sprite, const layer = cropAppearance(crop);
    world.getPtr(entity, render.Sprite).?.* = sprite;
    world.getPtr(entity, render.Render).?.layer = layer;
}

fn cropAppearance(crop: farm.Crop) struct { render.Sprite, render.Layer } {
    const sprite = cropStage(crop.kind, crop.stage).sprite;
    return .{
        .{ .image = resolveImage(sprite), .offset = sprite.offset },
        if (crop.stage == .seed) .crop else .actor,
    };
}

pub fn spawnPickup(world: *World, args: struct {
    item: item.ItemEnum,
    count: u32 = 1,
    origin: zhu.Vector2,
}) void {
    const config = itemConfig(args.item);
    const image = resolveImage(config.icon);
    // 地图掉落物使用原始像素尺寸，背包图标才使用配置中的 UI 尺寸。
    const size = image.size;
    const offset = size.scale(-0.5);

    // 在图标大小范围内随机一个落点，作为出生飞散动画的终点。
    const radius = @sqrt(zhu.random.float(0, 1)) * size.maxAxis();
    const angle = zhu.random.float(0, std.math.tau);
    const scatter = zhu.Vector2.xy(@cos(angle), @sin(angle)).scale(radius);

    const entity = world.createEntity();
    world.add(entity, args.origin);
    world.add(entity, item.Pickup{
        .item = args.item,
        .count = args.count,
    });
    world.add(entity, item.PickupMotion{
        .start = args.origin,
        .target = args.origin.add(scatter),
    });
    world.add(entity, motion.Shape{ .rect = .init(offset, size) });
    world.add(entity, render.Sprite{
        .image = image,
        .offset = offset,
        .size = size,
    });
    world.add(entity, render.Render{ .layer = .crop });
    world.add(entity, render.YSort{});
}

const expectEqual = std.testing.expectEqual;
test "spawnPlayer 会创建玩家实体" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    spawnPlayer(&world, .xy(160, 96), .down);

    const player = world.getIdentity(actor.Player).?;
    try expectEqual(160, world.get(player, component.Position).?.x);
    try expectEqual(1, world.getComponents(motion.Velocity).len);
    try expectEqual(1, world.getComponents(actor.Actor).len);
    try expectEqual(1, world.getComponents(render.Sprite).len);
    try expectEqual(1, world.getComponents(render.Render).len);
    try expectEqual(1, world.getComponents(render.YSort).len);
}

test "spawnPlayer 重复调用只保留一个玩家" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    spawnPlayer(&world, .xy(160, 96), .down);
    spawnPlayer(&world, .xy(200, 128), .down);

    const player = world.getIdentity(actor.Player).?;
    try expectEqual(200, world.get(player, component.Position).?.x);
    try expectEqual(1, world.getComponents(component.Position).len);
    try expectEqual(1, world.getComponents(motion.Velocity).len);
    try expectEqual(1, world.getComponents(actor.Actor).len);
}

test "spawnAnimal 会创建可漫游动物实体" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = spawnAnimal(&world, .cow);

    try expectEqual(actor.AnimalEnum.cow, world.get(entity, actor.Animal).?);
    try std.testing.expect(world.has(entity, actor.Npc));
    try std.testing.expect(world.has(entity, actor.Wander));
    try std.testing.expect(world.has(entity, actor.Life));
    try expectEqual(sound.Id.cow, world.get(entity, sound.Id).?);
    try expectEqual(0.4, world.get(entity, sound.Voice).?.probability);
    const life = world.get(entity, actor.Life).?;
    try std.testing.expectEqual(.normal, life.state);
    try std.testing.expect(life.timer >= 4);
    try std.testing.expect(life.timer <= 8);
    try expectEqual(null, world.get(entity, actor.Dialog));
}

test "spawnFriend 会创建可对话 NPC 实体" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = spawnFriend(&world);

    try std.testing.expect(world.has(entity, actor.Npc));
    try std.testing.expect(world.has(entity, actor.Wander));
    try std.testing.expect(world.has(entity, actor.Interact));
    const dialog = world.get(entity, actor.Dialog).?;
    try std.testing.expect(dialog.lines.len != 0);
}

test "地图摆件按底边定位生成实体" {
    const imageId = 1234;
    const tileSetId = 5678;

    const tiles = [_]tiled.Tile{
        .{
            .id = imageId,
            .objectGroup = null,
            .properties = &.{},
            .animation = &.{},
        },
    };
    const tileSets = [_]tiled.TileSet{
        .{
            .id = tileSetId,
            .columns = 0,
            .tileCount = 1,
            .image = imageId,
            .tileSize = .xy(16, 16),
            .tiles = &tiles,
        },
    };
    const testMap = tiled.Map{
        .grid = .{ .width = 1, .height = 1, .cellSide = 16 },
        .layers = &.{},
        .tileSets = &tileSets,
        .tileSetRefs = &.{.{ .firstGid = 1, .id = tileSetId }},
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = spawnMapObject(&world, testMap, .{
        .id = 1,
        .gid = 1,
        .name = "",
        .type = "",
        .position = .xy(12, 34),
        .size = .xy(20, 30),
        .point = false,
        .properties = &.{},
    });

    const position = world.get(entity, component.Position).?;
    const sprite = world.get(entity, render.Sprite).?;

    try expectEqual(12, position.x);
    try expectEqual(34, position.y);
    try expectEqual(-30, sprite.offset.y);
    try expectEqual(20, sprite.size.?.x);
    try expectEqual(30, sprite.size.?.y);
}

test "地图摆件优先用碰撞底边作为排序点" {
    const imageId = 1234;
    const tileSetId = 5678;

    const collisions = [_]tiled.Object{.{
        .id = 1,
        .gid = 0,
        .name = "",
        .type = "",
        .position = .xy(2, 12),
        .size = .xy(16, 8),
        .point = false,
        .properties = &.{},
    }};
    const tiles = [_]tiled.Tile{.{
        .id = imageId,
        .objectGroup = .{ .visible = true, .objects = &collisions },
        .properties = &.{},
        .animation = &.{},
    }};
    const tileSets = [_]tiled.TileSet{.{
        .id = tileSetId,
        .columns = 0,
        .tileCount = 1,
        .image = imageId,
        .tileSize = .xy(20, 40),
        .tiles = &tiles,
    }};
    const testMap = tiled.Map{
        .grid = .{ .width = 1, .height = 1, .cellSide = 16 },
        .layers = &.{},
        .tileSets = &tileSets,
        .tileSetRefs = &.{.{ .firstGid = 1, .id = tileSetId }},
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = spawnMapObject(&world, testMap, .{
        .id = 1,
        .gid = 1,
        .name = "",
        .type = "",
        .position = .xy(12, 50),
        .size = .xy(20, 40),
        .point = false,
        .properties = &.{},
    });

    const position = world.get(entity, component.Position).?;
    const sprite = world.get(entity, render.Sprite).?;

    try expectEqual(12, position.x);
    try expectEqual(30, position.y);
    try expectEqual(-20, sprite.offset.y);
    try expectEqual(10, position.y + sprite.offset.y);
}

test "带 anim_id 的地图摆件会创建停止的非循环动画" {
    const imageId = 1234;
    const tileSetId = 5678;

    const frames = [_]zhu.graphics.Frame{
        .{ .offset = .xy(0, 0), .duration = 0.1 },
        .{ .offset = .xy(16, 0), .duration = 0.1 },
    };
    const properties = [_]tiled.Property{
        .{ .name = "anim_id", .value = .{ .string = "open" } },
    };
    const tiles = [_]tiled.Tile{
        .{
            .id = 0,
            .objectGroup = null,
            .properties = &properties,
            .animation = &frames,
        },
    };
    const tileSets = [_]tiled.TileSet{
        .{
            .id = tileSetId,
            .columns = 2,
            .tileCount = 2,
            .image = imageId,
            .tileSize = .xy(16, 16),
            .tiles = &tiles,
        },
    };
    const testMap = tiled.Map{
        .grid = .{ .width = 1, .height = 1, .cellSide = 16 },
        .layers = &.{},
        .tileSets = &tileSets,
        .tileSetRefs = &.{.{ .firstGid = 1, .id = tileSetId }},
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = spawnMapObject(&world, testMap, .{
        .id = 1,
        .gid = 1,
        .name = "",
        .type = "",
        .position = .xy(12, 34),
        .size = .zero,
        .point = false,
        .properties = &.{},
    });

    const animation = world.get(entity, actor.Animation).?;
    const sprite = world.get(entity, render.Sprite).?;

    try std.testing.expect(!animation.source.loop);
    try std.testing.expect(animation.isFinished());
    try expectEqual(0, sprite.image.offset.x);
    try expectEqual(0, sprite.image.offset.y);
}
