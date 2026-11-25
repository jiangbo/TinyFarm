const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("../component.zig");
const factory = @import("../factory.zig");
const Inventory = @import("../resource/Inventory.zig");
const Map = @import("../resource/Map.zig");
const map = @import("../map.zig");

const Player = component.actor.Player;
const UseFrame = component.actor.UseFrame;
const WantUse = component.actor.WantUse;
const Animation = component.actor.Animation;
const Crop = component.farm.Crop;
const CropEnum = component.farm.CropEnum;
const ItemEnum = component.item.ItemEnum;
const Pickup = component.item.Pickup;
const Product = component.item.Product;
const event = component.event;
const render = component.render;
const World = ecs.World;

pub fn update(world: *World) void {
    updateTool(world);
    const days = world.getEvent(event.DayChanged);
    if (days.len == 0) return;

    const current = world.getResourcePtr(Map).?;
    for (days) |_| {
        for (current.tiles) |*tile| {
            // 浇水只影响当天，跨天后湿地变干。
            const watered = tile.ground == .wet;
            if (watered) tile.ground = .dry;

            const entity = tile.get(.crop) orelse continue;
            const crop = world.getPtr(entity, Crop).?;
            if (map.advanceCropOneDay(crop, watered)) {
                map.refreshCropSprite(world, entity, crop.*);
            }
            crop.watered = false;
        }
    }
}

fn updateTool(world: *World) void {
    const player = world.getIdentity(Player) orelse return;
    if (!world.has(player, UseFrame)) return;

    useItem(world, world.get(player, WantUse).?);

    // 一次动作只结算一次，结算后清理关键帧标记和意图。
    world.remove(player, UseFrame);
    world.remove(player, WantUse);
}

fn useItem(world: *World, want: WantUse) void {
    const current = world.getResourcePtr(Map).?;
    // WantUse.item 是点击瞬间锁定的物品，不读取当前快捷栏状态。
    switch (want.item) {
        .hoe => if (map.hoe(current, want.target)) {
            world.addEvent(event.SoundPlay{ .id = .hoe });
        },
        .water => water(world, current, want.target),
        .sickle => harvest(world, current, want.target),
        .strawberry_seed => useSeed(world, current, want, .strawberry),
        .potato_seed => useSeed(world, current, want, .potato),
        .pickaxe, .axe => hitProduct(world, current, want),
        .strawberry, .potato, .timber, .stone => unreachable,
    }
}

fn harvest(world: *World, current: *Map, position: zhu.Vector2) void {
    const tile = current.getTile(position) orelse return;
    const entity = tile.get(.crop) orelse return;
    const crop = world.get(entity, Crop).?;
    if (crop.stage != .mature) return;

    // 成熟作物先从地块移除，再生成一个可拾取产物。
    const item = factory.harvestItem(crop.kind);
    world.destroyEntity(entity);
    tile.object = null;
    factory.spawnPickup(world, .{
        .item = item,
        .origin = position.add(current.grid.halfCell()),
    });
    world.addEvent(event.SoundPlay{ .id = .harvest });
}

fn useSeed(world: *World, current: *Map, want: WantUse, kind: CropEnum) void {
    if (!current.canPlant(want.target)) return;
    const inv = world.getResourcePtr(Inventory).?;
    if (!inv.use(want.item, 1)) return;

    const crop = factory.spawnCrop(world, want.target, kind);
    current.getTile(want.target).?.set(.crop, crop);
    world.addEvent(event.SoundPlay{ .id = .plant });
}

fn water(world: *World, current: *Map, position: zhu.Vector2) void {
    if (!current.water(position)) return;

    const tile = current.getTile(position).?;
    if (tile.get(.crop)) |entity| {
        world.getPtr(entity, Crop).?.watered = true;
    }
    world.addEvent(event.SoundPlay{ .id = .water });
}

fn hitProduct(world: *World, current: *Map, want: WantUse) void {
    const hit = factory.itemConfig(want.item).hit.?;
    const tile = current.getTile(want.target) orelse return;
    const entity = tile.get(.product) orelse return;
    const product = world.getPtr(entity, Product).?;
    if (product.drop.item != hit.target) return;

    std.debug.assert(product.health > 0);
    product.health -= 1;
    // reset 后动画系统会在下一次 update 立即处理第一帧。
    if (world.getPtr(entity, Animation)) |a| a.reset();

    world.addEvent(event.SoundPlay{ .id = toolSound(want.item) });
    if (product.health != 0) return;

    // drop.count 表示最大掉落数量，实际掉落 1 到 count 个，
    // 合并为一个带数量的掉落物，拾取时一次性获得全部。
    std.debug.assert(product.drop.count > 0);
    const dropCount = zhu.random.intMost(u32, 1, product.drop.count);
    const origin = want.target.add(current.grid.halfCell());
    factory.spawnPickup(world, .{
        .item = product.drop.item,
        .count = dropCount,
        .origin = origin,
    });
    map.clearProduct(world, want.target);
}

fn toolSound(tool: ItemEnum) component.sound.Id {
    return switch (tool) {
        .axe => .axe,
        .pickaxe => .pickaxe,
        else => unreachable,
    };
}

const testMap = zhu.extend.tiled.Map{
    .grid = .{ .width = 4, .height = 5, .cellSide = 16 },
    .layers = &.{.{
        .id = 1,
        .name = "ground",
        .image = 0,
        .type = .tile,
        .offset = .zero,
        .data = &.{
            0, 0, 0,          0,
            0, 0, 0,          0,
            0, 0, 0,          0,
            0, 0, 0x01000000, 0x01000001,
            0, 0, 0,          0,
        },
        .objects = &.{},
    }},
    .tileSets = &.{.{
        .id = 1,
        .columns = 1,
        .tileCount = 1,
        .image = 0,
        .tileSize = .xy(16, 16),
        .tiles = &.{
            .{
                .id = 0,
                .objectGroup = null,
                .properties = &.{.{
                    .name = "tile_flag",
                    .value = .{ .string = "ARABLE" },
                }},
                .animation = &.{},
            },
            .{
                .id = 1,
                .objectGroup = null,
                .properties = &.{.{
                    .name = "tile_flag",
                    .value = .{ .string = "ARABLE,SOLID" },
                }},
                .animation = &.{},
            },
        },
    }},
};

fn loadTestMap(world: *World) *Map {
    map.load(std.testing.allocator, world, testMap);
    return world.getResourcePtr(Map).?;
}

fn testInventory(world: *World) *Inventory {
    if (world.getResourcePtr(Inventory)) |inv| return inv;
    world.addResource(Inventory{});
    return world.getResourcePtr(Inventory).?;
}

fn setActiveItem(world: *World, item: ItemEnum, count: u32) void {
    const inv = testInventory(world);
    inv.reset();
    _ = inv.add(item, count);
}

fn addProduct(world: *World, target: zhu.Vector2, product: Product) ecs.Entity {
    const entity = world.createEntity();
    world.add(entity, product);
    world.getResourcePtr(Map).?.getTile(target).?.set(.product, entity);
    return entity;
}

test "toolHit 会按 WantUse 锄地" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .hoe, .target = target });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expect(current.canPlant(target));
    try std.testing.expect(!world.has(player, WantUse));

    const sounds = world.getEvent(event.SoundPlay);
    try std.testing.expectEqual(1, sounds.len);
    try std.testing.expectEqual(.hoe, sounds[0].id);
}

test "非事件帧不会结算 WantUse" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .hoe, .target = target });

    update(&world);

    try std.testing.expect(!current.canPlant(target));
    try std.testing.expect(world.has(player, WantUse));
}

test "seedPlant 会种植并扣种子" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const inv = testInventory(&world);
    setActiveItem(&world, .strawberry_seed, 2);
    try std.testing.expect(map.hoe(current, target));

    const player = world.createIdentity(Player);
    world.add(player, WantUse{
        .item = .strawberry_seed,
        .target = target,
    });
    world.add(player, UseFrame{});

    update(&world);

    const index = inv.hotbar[inv.activeHotbar].?;
    try std.testing.expectEqual(1, inv.store.get(index).?.count);

    const cropEntity = current.getTile(target).?.get(.crop).?;
    try std.testing.expectEqual(
        CropEnum.strawberry,
        world.get(cropEntity, Crop).?.kind,
    );

    const sounds = world.getEvent(event.SoundPlay);
    try std.testing.expectEqual(1, sounds.len);
    try std.testing.expectEqual(.plant, sounds[0].id);
}

test "seedPlant 没有种子时不会种植" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    _ = testInventory(&world);
    try std.testing.expect(map.hoe(current, target));

    const player = world.createIdentity(Player);
    world.add(player, WantUse{
        .item = .strawberry_seed,
        .target = target,
    });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expectEqual(null, current.getTile(target).?.get(.crop));
    try std.testing.expectEqual(0, world.getEvent(event.SoundPlay).len);
}

test "seedPlant 无耕地时不扣种子" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const inv = testInventory(&world);
    setActiveItem(&world, .strawberry_seed, 2);

    const player = world.createIdentity(Player);
    world.add(player, WantUse{
        .item = .strawberry_seed,
        .target = target,
    });
    world.add(player, UseFrame{});

    update(&world);

    const index = inv.hotbar[inv.activeHotbar].?;
    try std.testing.expectEqual(2, inv.store.get(index).?.count);
    try std.testing.expectEqual(null, current.getTile(target).?.get(.crop));
    try std.testing.expectEqual(0, world.getEvent(event.SoundPlay).len);
}

test "seedPlant 已有作物时不扣种子" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const inv = testInventory(&world);
    setActiveItem(&world, .strawberry_seed, 2);
    try std.testing.expect(map.hoe(current, target));
    const oldCrop = world.createEntity();
    world.add(oldCrop, Crop{ .kind = .potato });
    current.getTile(target).?.set(.crop, oldCrop);

    const player = world.createIdentity(Player);
    world.add(player, WantUse{
        .item = .strawberry_seed,
        .target = target,
    });
    world.add(player, UseFrame{});

    update(&world);

    const index = inv.hotbar[inv.activeHotbar].?;
    try std.testing.expectEqual(2, inv.store.get(index).?.count);
    try std.testing.expectEqual(oldCrop, current.getTile(target).?.get(.crop).?);
    try std.testing.expectEqual(0, world.getEvent(event.SoundPlay).len);
}

test "浇水只作用于耕地并标记地里的作物" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const tile = current.getTile(target).?;
    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .water, .target = target });
    world.add(player, UseFrame{});
    update(&world);
    try std.testing.expectEqual(null, tile.ground);
    try std.testing.expectEqual(0, world.getEvent(event.SoundPlay).len);

    try std.testing.expect(map.hoe(current, target));
    const crop = world.createEntity();
    world.add(crop, Crop{});
    tile.set(.crop, crop);
    world.add(player, WantUse{ .item = .water, .target = target });
    world.add(player, UseFrame{});
    update(&world);

    try std.testing.expectEqual(.wet, tile.ground);
    try std.testing.expect(world.get(crop, Crop).?.watered);

    const sounds = world.getEvent(event.SoundPlay);
    try std.testing.expectEqual(1, sounds.len);
    try std.testing.expectEqual(.water, sounds[0].id);
}

test "当前地图跨天推进作物后刷新贴图和渲染层" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const target = zhu.Vector2.xy(32, 48);
    const crop = world.createEntity();
    world.add(crop, Crop{
        .kind = .strawberry,
        .stage = .seed,
        .next = 1,
    });
    world.add(crop, render.Sprite{ .image = .{} });
    world.add(crop, render.Render{ .layer = .crop });
    const tile = current.getTile(target).?;
    tile.ground = .dry;
    tile.set(.crop, crop);
    world.addEvent(event.DayChanged{ .day = 2 });

    update(&world);

    const result = world.get(crop, Crop).?;
    const stage = factory.cropStage(.strawberry, .sprout);
    try std.testing.expectEqual(component.farm.GrowthEnum.sprout, result.stage);
    try std.testing.expectEqual(stage.duration, result.next);
    try std.testing.expectEqual(
        stage.sprite.offset,
        world.get(crop, render.Sprite).?.offset,
    );
    try std.testing.expectEqual(
        render.Layer.actor,
        world.get(crop, render.Render).?.layer,
    );
}

test "同一帧先浇水，再结算跨天生长" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const target = zhu.Vector2.xy(32, 48);
    const crop = world.createEntity();
    world.add(crop, Crop{
        .kind = .strawberry,
        .stage = .seed,
        .next = 4,
    });
    const tile = current.getTile(target).?;
    tile.ground = .dry;
    tile.set(.crop, crop);
    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .water, .target = target });
    world.add(player, UseFrame{});
    world.addEvent(event.DayChanged{ .day = 2 });

    update(&world);

    const result = world.get(crop, Crop).?;
    try std.testing.expectEqual(@as(f32, 2), result.next);
    try std.testing.expectEqual(component.farm.Ground.dry, tile.ground);
}

test "斧头命中木材产出对象会减少生命" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const entity = addProduct(&world, target, .{ .drop = .one(.timber), .health = 2 });
    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .axe, .target = target });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expectEqual(entity, current.getTile(target).?.get(.product).?);
    try std.testing.expectEqual(1, world.get(entity, Product).?.health);
    try std.testing.expectEqual(0, world.getComponents(Pickup).len);

    const sounds = world.getEvent(event.SoundPlay);
    try std.testing.expectEqual(1, sounds.len);
    try std.testing.expectEqual(.axe, sounds[0].id);
}

test "斧头命中产出对象会播放地图资源动画" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    _ = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const entity = addProduct(&world, target, .{ .drop = .one(.timber), .health = 2 });
    const image = zhu.Image{ .size = .xy(32, 16) };
    const frames = [_]zhu.graphics.Frame{
        .{ .offset = .xy(0, 0), .duration = 0.1 },
        .{ .offset = .xy(16, 0), .duration = 0.1 },
    };
    var animation = Animation.init(image, .xy(16, 16), &frames);
    animation.source.loop = false;
    animation.stop();
    world.add(entity, animation);

    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .axe, .target = target });
    world.add(player, UseFrame{});

    update(&world);

    const result = world.get(entity, Animation).?;
    try std.testing.expect(result.isRunning());
}

test "错误工具不会命中产出对象" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const entity = addProduct(&world, target, .{ .drop = .one(.stone), .health = 2 });
    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .axe, .target = target });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expectEqual(entity, current.getTile(target).?.get(.product).?);
    try std.testing.expectEqual(2, world.get(entity, Product).?.health);
    try std.testing.expectEqual(0, world.getComponents(Pickup).len);
    try std.testing.expectEqual(0, world.getEvent(event.SoundPlay).len);
}

test "镐子击碎石头会生成掉落" {
    const target = zhu.Vector2.xy(32, 48);
    zhu.random.init(1);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    const entity = addProduct(&world, target, .{
        .drop = .{ .item = .stone, .count = 2 },
        .health = 1,
    });
    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .pickaxe, .target = target });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expectEqual(null, current.getTile(target).?.get(.product));
    try std.testing.expect(!world.has(entity, Product));

    const pickups = world.getComponents(Pickup);
    try std.testing.expectEqual(1, pickups.len);
    try std.testing.expectEqual(ItemEnum.stone, pickups[0].item);
    try std.testing.expect(pickups[0].count >= 1);
    try std.testing.expect(pickups[0].count <= 2);

    const sounds = world.getEvent(event.SoundPlay);
    try std.testing.expectEqual(1, sounds.len);
    try std.testing.expectEqual(.pickaxe, sounds[0].id);
}

test "sickle 会收获成熟作物并生成掉落物" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    try std.testing.expect(map.hoe(current, target));
    const crop = world.createEntity();
    world.add(crop, Crop{ .stage = .mature, .kind = .potato });
    current.getTile(target).?.set(.crop, crop);

    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .sickle, .target = target });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expectEqual(null, current.getTile(target).?.get(.crop));
    try std.testing.expectEqual(null, world.get(crop, Crop));

    const pickups = world.getComponents(Pickup);
    try std.testing.expectEqual(1, pickups.len);
    try std.testing.expectEqual(ItemEnum.potato, pickups[0].item);

    const sounds = world.getEvent(event.SoundPlay);
    try std.testing.expectEqual(1, sounds.len);
    try std.testing.expectEqual(.harvest, sounds[0].id);
}

test "hoe 不会收获成熟作物" {
    const target = zhu.Vector2.xy(32, 48);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = loadTestMap(&world);
    defer map.unload(std.testing.allocator, &world);

    try std.testing.expect(map.hoe(current, target));
    const crop = world.createEntity();
    world.add(crop, Crop{ .stage = .mature, .kind = .potato });
    current.getTile(target).?.set(.crop, crop);

    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .hoe, .target = target });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expectEqual(crop, current.getTile(target).?.get(.crop).?);
    try std.testing.expectEqual(0, world.getComponents(Pickup).len);
    try std.testing.expectEqual(0, world.getEvent(event.SoundPlay).len);
}
