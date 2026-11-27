const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("../component.zig");

const Map = @This();
const Allocator = std.mem.Allocator;
const Entity = ecs.Entity;
const spatial = zhu.extend.spatial;
const tiled = zhu.extend.tiled;
const farm = component.farm;
const SolidRange = component.map.SolidRange;
const AnimatedTile = struct { vertex: usize, animation: zhu.Animation };

const Soil = struct {
    rules: *const tiled.WangSet,
    columns: u32,
    tileSize: zhu.Vector2,
    image: zhu.Image,
};

const TileObject = struct {
    const Kind = enum { crop, product, chest };
    kind: Kind,
    entity: Entity,
};

const Mark = enum {
    hazard, // 危险区域
    water, // 水域
    interact, // 可交互
    arable, // 可耕作
    occupied, // 被占用
};

pub const Tile = struct {
    ground: ?farm.Ground = null,
    object: ?TileObject = null,
    gone: enum { none, product } = .none,
    marks: std.EnumSet(Mark) = .empty,

    pub fn get(self: Tile, kind: TileObject.Kind) ?Entity {
        const object = self.object orelse return null;
        if (object.kind != kind) return null;
        return object.entity;
    }

    pub fn set(self: *Tile, kind: TileObject.Kind, entity: Entity) void {
        self.object = .{ .kind = kind, .entity = entity };
    }
};

id: component.map.Id,
grid: spatial.Grid = undefined,
props: struct {
    outdoor: bool = false,
    indoorAmbient: zhu.Color = .white,
    playerSpawn: ?zhu.Vector2 = null,
} = .{},
tiles: []Tile = &.{},
collision: spatial.Static = .{},
areas: std.ArrayList(zhu.Rect) = .empty,
vertexes: std.ArrayList(zhu.Vertex) = .empty,
animatedTiles: std.ArrayList(AnimatedTile) = .empty,
frontStart: usize = 0,
soil: ?Soil = null,
groundVertexes: std.ArrayList(zhu.Vertex) = .empty,
groundDirty: bool = true,

pub fn init(gpa: Allocator, id: component.map.Id, grid: spatial.Grid) Map {
    const tiles = gpa.alloc(Tile, grid.count()) catch zhu.oom();
    @memset(tiles, .{});
    return .{ .id = id, .grid = grid, .tiles = tiles };
}

pub fn bindSoil(self: *Map, sets: []const tiled.TileSet) void {
    std.debug.assert(self.soil == null);
    for (sets) |set| {
        const rules = set.getWangSet("soil") orelse continue;
        std.debug.assert(set.columns != 0);
        const image = zhu.assets.getImage(set.image) orelse
            zhu.panic("missing soil image {} in atlas", .{set.image});
        self.soil = .{
            .rules = rules,
            .columns = set.columns,
            .tileSize = set.tileSize,
            .image = image,
        };
        return;
    }
    @panic("soil terrain rules are missing from maps/tileSet.zlib");
}

pub fn deinit(self: *Map, gpa: Allocator) void {
    gpa.free(self.tiles);
    self.collision.deinit(gpa);
    self.areas.clearAndFree(gpa);
    self.vertexes.clearAndFree(gpa);
    self.groundVertexes.clearAndFree(gpa);
    self.animatedTiles.clearAndFree(gpa);
}

pub fn setGround(self: *Map, index: usize, ground: ?farm.Ground) void {
    const tile = &self.tiles[index];
    if (tile.ground == ground) return;
    tile.ground = ground;
    self.groundDirty = true;
}

/// 地表变化后整图重建，保留数组容量；由 render.update 调用，draw 只提交结果。
pub fn updateGround(self: *Map, gpa: Allocator) void {
    if (!self.groundDirty) return;
    const soil = self.soil.?;
    self.groundVertexes.clearRetainingCapacity();
    for (self.tiles, 0..) |tile, index| {
        const ground = tile.ground orelse continue;
        const position = self.grid.indexToWorld(index);
        const layers: usize = if (ground == .wet) 2 else 1;
        for (0..layers) |layer| {
            const id = groundTileId(self, index, layer == 1);
            const col: f32 = @floatFromInt(id % soil.columns);
            const row: f32 = @floatFromInt(id / soil.columns);
            const offset = zhu.Vector2.xy(col, row).mul(soil.tileSize);
            const image = soil.image.sub(.init(offset, soil.tileSize));
            self.groundVertexes.append(gpa, .{
                .position = position,
                .layer = image.layer,
                .size = image.size,
                .uvRect = image.uvRect(),
            }) catch zhu.oom();
        }
    }
    self.groundDirty = false;
}

pub fn advanceAnimations(self: *Map, delta: f32) void {
    for (self.animatedTiles.items) |*tile| {
        if (!tile.animation.update(delta)) continue;
        const image = tile.animation.subImage();
        self.vertexes.items[tile.vertex].uvRect = image.uvRect();
    }
}

pub fn drawBack(self: *const Map, image: zhu.Image) void {
    const vertexes = self.vertexes.items;
    if (vertexes.len == 0) return;
    zhu.batch.drawVertices(image, vertexes[0..self.frontStart]);
}

pub fn drawGround(self: *const Map) void {
    std.debug.assert(!self.groundDirty);
    if (self.groundVertexes.items.len == 0) return;
    zhu.batch.drawVertices(self.soil.?.image, self.groundVertexes.items);
}

pub fn drawFront(self: *const Map, image: zhu.Image) void {
    const front = self.vertexes.items[self.frontStart..];
    if (front.len != 0) zhu.batch.drawVertices(image, front);
}

pub fn getTile(self: *const Map, position: zhu.Vector2) ?*Tile {
    const index = self.grid.worldToIndex(position) orelse return null;
    return &self.tiles[index];
}

// 清除默认产出对象，标记为 gone，防止读档时重建。
pub fn clearProduct(self: *Map, index: usize, solid: ?SolidRange) void {
    const entity = self.tiles[index].get(.product).?;
    if (solid) |range| {
        const areas = self.areas.items[range.start..][0..range.count];
        for (areas) |*area| area.* = .init(.zero, .zero);
    }
    for (self.tiles) |*tile| {
        if (tile.get(.product) == entity) tile.object = null;
    }
    // gone 只记录在触发销毁的格子上。
    self.tiles[index].gone = .product;
}

fn groundTileId(current: *const Map, index: usize, wet: bool) u32 {
    const Cell = zhu.extend.spatial.Cell;
    const rules = current.soil.?.rules;
    const color = rules.getColorIndex(if (wet) "wet" else "tilled").?;
    const width: usize = @intCast(current.grid.width);
    const cell = Cell.xy(@intCast(index % width), @intCast(index / width));
    const offsets = [_]Cell{
        Cell.xy(0, -1), Cell.xy(1, -1), Cell.xy(1, 0),  Cell.xy(1, 1),
        Cell.xy(0, 1),  Cell.xy(-1, 1), Cell.xy(-1, 0), Cell.xy(-1, -1),
    };
    var colors: [8]u8 = @splat(0);
    for (offsets, 0..) |offset, i| {
        const neighbor = Cell.xy(cell.x + offset.x, cell.y + offset.y);
        const next = current.grid.cellToIndex(neighbor) orelse continue;
        const ground = current.tiles[next].ground orelse continue;
        if (!wet or ground == .wet) colors[i] = color;
    }
    // 对角连接仅在相邻两条边都连接时生效。
    for ([_]usize{ 1, 3, 5, 7 }) |i| {
        if (colors[i - 1] == 0 or colors[(i + 1) % 8] == 0) colors[i] = 0;
    }
    // 素材未定义孤立格规则，沿用原有的干地和湿地单格贴图。
    if (std.mem.allEqual(u8, &colors, 0)) return if (wet) 84 else 72;
    return rules.getTileId(colors).?;
}

const testSoil: Soil = .{
    .rules = &.{
        .name = "soil",
        .type = .mixed,
        .colors = &.{ "tilled", "wet" },
        .tiles = &.{
            .{ .tileId = 80, .colors = .{ 1, 1, 1, 0, 0, 0, 0, 0 } },
            .{ .tileId = 60, .colors = .{ 2, 0, 0, 0, 0, 0, 0, 0 } },
        },
    },
    .columns = 24,
    .tileSize = .all(16),
    .image = .{ .size = .xy(384, 128) },
};

test "耕地跨干湿连接，湿地只连接湿地，孤立格忽略对角邻居" {
    var current = Map.init(std.testing.allocator, .home_exterior, .{
        .width = 3,
        .height = 3,
        .cellSide = 16,
    });
    defer current.deinit(std.testing.allocator);
    current.soil = testSoil;
    current.setGround(4, .wet);
    current.setGround(1, .wet);
    current.setGround(2, .wet);
    current.setGround(5, .dry);

    try std.testing.expectEqual(80, groundTileId(&current, 4, false));
    try std.testing.expectEqual(60, groundTileId(&current, 4, true));

    current.setGround(1, .dry);
    try std.testing.expectEqual(80, groundTileId(&current, 4, false));
    try std.testing.expectEqual(84, groundTileId(&current, 4, true));

    current.setGround(1, null);
    current.setGround(5, null);
    try std.testing.expectEqual(72, groundTileId(&current, 4, false));
    try std.testing.expectEqual(84, groundTileId(&current, 4, true));
}

test "地表缓存重建不残留旧湿地层或已清除地块" {
    const gpa = std.testing.allocator;
    var current = Map.init(gpa, .home_exterior, .{
        .width = 1,
        .height = 1,
        .cellSide = 16,
    });
    defer current.deinit(gpa);
    current.soil = testSoil;

    current.setGround(0, .wet);
    current.updateGround(gpa);
    try std.testing.expectEqual(2, current.groundVertexes.items.len);

    current.setGround(0, .dry);
    current.updateGround(gpa);
    try std.testing.expectEqual(1, current.groundVertexes.items.len);

    current.setGround(0, null);
    current.updateGround(gpa);
    try std.testing.expectEqual(0, current.groundVertexes.items.len);
}
