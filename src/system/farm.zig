const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("../component.zig");
const factory = @import("../factory.zig");
const Inventory = @import("../resource/Inventory.zig");
const Map = @import("../resource/Map.zig");

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
            if (factory.advanceCropOneDay(crop, watered)) {
                factory.refreshCropSprite(world, entity, crop.*);
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
        .hoe => if (hoe(current, want.target)) {
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

fn hoe(current: *Map, position: zhu.Vector2) bool {
    const index = current.grid.worldToIndex(position) orelse return false;
    const tile = &current.tiles[index];
    if (tile.ground != null or tile.object != null) return false;
    const marks = tile.marks;
    if (!marks.contains(.arable)) return false;
    if (marks.contains(.water)) return false;
    if (marks.contains(.occupied)) return false;
    const body: zhu.Shape = .{ .rect = current.grid.indexToRect(index) };
    if (current.collision.overlaps(body)) return false;
    tile.ground = .dry;
    return true;
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
    const tile = current.getTile(want.target) orelse return;
    if (tile.ground == null or tile.object != null) return;

    const inv = world.getResourcePtr(Inventory).?;
    if (!inv.use(want.item, 1)) return;

    const stage = factory.cropStage(kind, .seed);
    const crop = factory.spawnCrop(world, want.target, .{
        .kind = kind,
        .next = stage.duration,
    });
    tile.set(.crop, crop);
    world.addEvent(event.SoundPlay{ .id = .plant });
}

fn water(world: *World, current: *Map, position: zhu.Vector2) void {
    const tile = current.getTile(position) orelse return;
    if (tile.ground == null) return;
    tile.ground = .wet;

    if (tile.get(.crop)) |entity| {
        world.getPtr(entity, Crop).?.watered = true;
    }
    world.addEvent(event.SoundPlay{ .id = .water });
}

fn hitProduct(world: *World, current: *Map, want: WantUse) void {
    const hit = factory.itemConfig(want.item).hit.?;
    const index = current.grid.worldToIndex(want.target) orelse return;
    const entity = current.tiles[index].get(.product) orelse return;
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
    const solid = world.get(entity, component.map.SolidRange);
    current.clearProduct(index, solid);
    world.destroyEntity(entity);
}

fn toolSound(tool: ItemEnum) component.sound.Id {
    return switch (tool) {
        .axe => .axe,
        .pickaxe => .pickaxe,
        else => unreachable,
    };
}

const testTarget = zhu.Vector2.zero;

fn addTestMap(world: *World) *Map {
    world.addResource(Map.init(std.testing.allocator, .school, .{
        .width = 1,
        .height = 1,
        .cellSide = 16,
    }));
    const current = world.getResourcePtr(Map).?;
    current.tiles[0].marks.insert(.arable);
    return current;
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

fn addTestProduct(world: *World, product: Product) ecs.Entity {
    const entity = world.createEntity();
    world.add(entity, product);
    world.getResourcePtr(Map).?.getTile(testTarget).?.set(.product, entity);
    return entity;
}

test "锄地要求可耕作且没有地图阻挡语义" {
    const gpa = std.testing.allocator;
    const grid: zhu.extend.spatial.Grid = .{ .width = 1, .height = 1, .cellSide = 16 };
    var tiles = [_]Map.Tile{.{}};
    const tile = &tiles[0];
    var current: Map = .{ .id = .school, .grid = grid, .tiles = &tiles };
    current.collision.mask = try .init(gpa, grid);
    defer current.collision.deinit(gpa);

    const position = zhu.Vector2.xy(8, 8);
    try std.testing.expect(!hoe(&current, position));

    tile.marks.insert(.arable);
    try std.testing.expect(hoe(&current, position));
    try std.testing.expectEqual(.dry, tile.ground);
    try std.testing.expect(!hoe(&current, position));
    tile.ground = null;

    tile.set(.crop, 0);
    try std.testing.expect(!hoe(&current, position));
    tile.object = null;

    tile.marks.insert(.water);
    try std.testing.expect(!hoe(&current, position));
    tile.marks.remove(.water);

    tile.marks.insert(.occupied);
    try std.testing.expect(!hoe(&current, position));
    tile.marks.remove(.occupied);

    current.collision.setCellsInRect(grid.indexToRect(0));
    try std.testing.expect(!hoe(&current, position));
}

test "锄地在工具动作的生效帧结算" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = addTestMap(&world);
    defer current.deinit(std.testing.allocator);

    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .hoe, .target = testTarget });
    update(&world);
    try std.testing.expectEqual(null, current.getTile(testTarget).?.ground);

    world.add(player, UseFrame{});
    update(&world);
    try std.testing.expectEqual(.dry, current.getTile(testTarget).?.ground);
}

test "seedPlant 会种植并扣种子" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = addTestMap(&world);
    defer current.deinit(std.testing.allocator);

    const inv = testInventory(&world);
    setActiveItem(&world, .strawberry_seed, 2);
    current.getTile(testTarget).?.ground = .dry;

    const player = world.createIdentity(Player);
    world.add(player, WantUse{
        .item = .strawberry_seed,
        .target = testTarget,
    });
    world.add(player, UseFrame{});

    update(&world);

    const index = inv.hotbar[inv.activeHotbar.?].?;
    try std.testing.expectEqual(1, inv.store.get(index).?.count);

    const cropEntity = current.getTile(testTarget).?.get(.crop).?;
    const crop = world.get(cropEntity, Crop).?;
    try std.testing.expectEqual(.strawberry, crop.kind);
    try std.testing.expectEqual(.seed, crop.stage);
}

test "seedPlant 没有种子时不会种植" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = addTestMap(&world);
    defer current.deinit(std.testing.allocator);

    _ = testInventory(&world);
    current.getTile(testTarget).?.ground = .dry;

    const player = world.createIdentity(Player);
    world.add(player, WantUse{
        .item = .strawberry_seed,
        .target = testTarget,
    });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expectEqual(null, current.getTile(testTarget).?.get(.crop));
}

test "seedPlant 无耕地时不扣种子" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = addTestMap(&world);
    defer current.deinit(std.testing.allocator);

    const inv = testInventory(&world);
    setActiveItem(&world, .strawberry_seed, 2);

    const player = world.createIdentity(Player);
    world.add(player, WantUse{
        .item = .strawberry_seed,
        .target = testTarget,
    });
    world.add(player, UseFrame{});

    update(&world);

    const index = inv.hotbar[inv.activeHotbar.?].?;
    try std.testing.expectEqual(2, inv.store.get(index).?.count);
    try std.testing.expectEqual(null, current.getTile(testTarget).?.get(.crop));
}

test "seedPlant 已有作物时不扣种子" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = addTestMap(&world);
    defer current.deinit(std.testing.allocator);

    const inv = testInventory(&world);
    setActiveItem(&world, .strawberry_seed, 2);
    current.getTile(testTarget).?.ground = .dry;
    const oldCrop = world.createEntity();
    world.add(oldCrop, Crop{ .kind = .potato });
    current.getTile(testTarget).?.set(.crop, oldCrop);

    const player = world.createIdentity(Player);
    world.add(player, WantUse{
        .item = .strawberry_seed,
        .target = testTarget,
    });
    world.add(player, UseFrame{});

    update(&world);

    const index = inv.hotbar[inv.activeHotbar.?].?;
    try std.testing.expectEqual(2, inv.store.get(index).?.count);
    try std.testing.expectEqual(oldCrop, current.getTile(testTarget).?.get(.crop).?);
}

test "浇水只作用于耕地" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = addTestMap(&world);
    defer current.deinit(std.testing.allocator);

    const tile = current.getTile(testTarget).?;
    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .water, .target = testTarget });
    world.add(player, UseFrame{});
    update(&world);
    try std.testing.expectEqual(null, tile.ground);

    tile.ground = .dry;
    world.add(player, WantUse{ .item = .water, .target = testTarget });
    world.add(player, UseFrame{});
    update(&world);

    try std.testing.expectEqual(.wet, tile.ground);
}

test "同一帧先浇水，再结算跨天生长" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = addTestMap(&world);
    defer current.deinit(std.testing.allocator);

    const crop = world.createEntity();
    world.add(crop, Crop{
        .kind = .strawberry,
        .stage = .seed,
        .next = 4,
    });
    const tile = current.getTile(testTarget).?;
    tile.ground = .dry;
    tile.set(.crop, crop);
    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .water, .target = testTarget });
    world.add(player, UseFrame{});
    world.addEvent(event.DayChanged{ .day = 2 });

    update(&world);

    const result = world.get(crop, Crop).?;
    try std.testing.expectEqual(@as(f32, 2), result.next);
    try std.testing.expectEqual(component.farm.Ground.dry, tile.ground);
}

test "斧头命中木材产出对象会减少生命" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = addTestMap(&world);
    defer current.deinit(std.testing.allocator);

    const entity = addTestProduct(&world, .{ .drop = .one(.timber), .health = 2 });
    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .axe, .target = testTarget });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expectEqual(entity, current.getTile(testTarget).?.get(.product).?);
    try std.testing.expectEqual(1, world.get(entity, Product).?.health);
    try std.testing.expectEqual(0, world.getComponents(Pickup).len);
}

test "错误工具不会命中产出对象" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = addTestMap(&world);
    defer current.deinit(std.testing.allocator);

    const entity = addTestProduct(&world, .{ .drop = .one(.stone), .health = 2 });
    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .axe, .target = testTarget });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expectEqual(entity, current.getTile(testTarget).?.get(.product).?);
    try std.testing.expectEqual(2, world.get(entity, Product).?.health);
    try std.testing.expectEqual(0, world.getComponents(Pickup).len);
}

test "镐子击碎石头会生成掉落" {
    zhu.random.init(1);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = addTestMap(&world);
    defer current.deinit(std.testing.allocator);

    const entity = addTestProduct(&world, .{
        .drop = .{ .item = .stone, .count = 2 },
        .health = 1,
    });
    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .pickaxe, .target = testTarget });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expectEqual(null, current.getTile(testTarget).?.get(.product));
    try std.testing.expect(!world.has(entity, Product));

    const pickups = world.getComponents(Pickup);
    try std.testing.expectEqual(1, pickups.len);
    try std.testing.expectEqual(ItemEnum.stone, pickups[0].item);
    try std.testing.expect(pickups[0].count >= 1);
    try std.testing.expect(pickups[0].count <= 2);
}

test "sickle 会收获成熟作物并生成掉落物" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const current = addTestMap(&world);
    defer current.deinit(std.testing.allocator);

    current.getTile(testTarget).?.ground = .dry;
    const crop = world.createEntity();
    world.add(crop, Crop{ .stage = .mature, .kind = .potato });
    current.getTile(testTarget).?.set(.crop, crop);

    const player = world.createIdentity(Player);
    world.add(player, WantUse{ .item = .sickle, .target = testTarget });
    world.add(player, UseFrame{});

    update(&world);

    try std.testing.expectEqual(null, current.getTile(testTarget).?.get(.crop));
    try std.testing.expectEqual(null, world.get(crop, Crop));

    const pickups = world.getComponents(Pickup);
    try std.testing.expectEqual(1, pickups.len);
    try std.testing.expectEqual(ItemEnum.potato, pickups[0].item);
}
