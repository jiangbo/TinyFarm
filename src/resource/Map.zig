const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("../component.zig");

const Map = @This();
const Allocator = std.mem.Allocator;
const Entity = ecs.Entity;
const spatial = zhu.extend.spatial;
const Grid = spatial.Grid;
const farm = component.farm;
const SolidRange = component.map.SolidRange;
const AnimatedTile = struct { vertex: usize, animation: zhu.Animation };

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

id: component.map.Id = .school,
grid: Grid = undefined,
props: struct {
    outdoor: bool = false,
    indoorAmbient: zhu.Color = .white,
} = .{},
tiles: []Tile = &.{},
collision: spatial.Static = .{},
areas: std.ArrayList(zhu.Rect) = .empty,
vertexes: std.ArrayList(zhu.Vertex) = .empty,
animatedTiles: std.ArrayList(AnimatedTile) = .empty,
frontStart: usize = 0,

pub fn init(gpa: Allocator, grid: Grid) Map {
    const tiles = gpa.alloc(Tile, grid.count()) catch zhu.oom();
    @memset(tiles, .{});
    return .{ .grid = grid, .tiles = tiles };
}

pub fn deinit(self: *Map, gpa: Allocator) void {
    gpa.free(self.tiles);
    self.tiles = &.{};
    self.collision.deinit(gpa);
    self.areas.clearAndFree(gpa);
    self.vertexes.clearAndFree(gpa);
    self.animatedTiles.clearAndFree(gpa);
    self.frontStart = 0;
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
    // 只有前景时也要为后续耕地顶点开启批次。
    zhu.batch.drawVertices(image, vertexes[0..self.frontStart]);
}

pub fn drawGround(self: *const Map, dry: zhu.Image, wet: zhu.Image) void {
    for (self.tiles, 0..) |tile, index| {
        const ground = tile.ground orelse continue;
        const position = self.grid.indexToWorld(index);
        appendGroundVertex(position, dry);
        if (ground == .wet) appendGroundVertex(position, wet);
    }
}

pub fn drawFront(self: *const Map, image: zhu.Image) void {
    const front = self.vertexes.items[self.frontStart..];
    if (front.len != 0) zhu.batch.drawVertices(image, front);
}

fn appendGroundVertex(position: zhu.Vector2, image: zhu.Image) void {
    zhu.assets.gpu.addVertex(.{
        .position = position,
        .layer = image.layer,
        .size = image.size,
        .uvRect = image.uvRect(),
    });
}

// SolidRange 只记录对象加入 areas 时的起点和数量。
pub fn solidAreas(self: *const Map, range: SolidRange) []zhu.Rect {
    return self.areas.items[range.start..][0..range.count];
}

pub fn getTile(self: *const Map, position: zhu.Vector2) ?*Tile {
    const index = self.grid.worldToIndex(position) orelse return null;
    return &self.tiles[index];
}
