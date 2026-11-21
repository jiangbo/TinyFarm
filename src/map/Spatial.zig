const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("../component.zig");

const Grid = zhu.extend.grid.Grid;
const SolidMask = zhu.extend.grid.SolidMask;
const Vector2 = zhu.Vector2;
const Position = component.Position;
const Shape = component.motion.Shape;
const Blocking = component.motion.Blocking;
const World = ecs.World;
const Entity = ecs.Entity;
const SolidRange = component.map.SolidRange;

const Spatial = @This();

// 当前地图每个瓦片上的语义标记，可组合使用。
pub const Mark = enum {
    hazard, // 危险区域
    water, // 水域
    interact, // 可交互
    arable, // 可耕作
    occupied, // 被占用
};

pub const Marks = std.EnumSet(Mark);

grid: Grid = undefined,
mask: SolidMask = undefined,
tiles: []Marks = &.{},
areas: std.ArrayList(zhu.Rect) = .empty,

pub fn init(gpa: zhu.Allocator, grid: Grid) Spatial {
    var self = Spatial{
        .grid = grid,
        .mask = SolidMask.init(gpa, .{
            .width = grid.width * 2,
            .height = grid.height * 2,
            .cell = @divExact(grid.cell, 2),
        }) catch zhu.oom(),
    };
    self.tiles = gpa.alloc(Marks, self.grid.count()) catch zhu.oom();
    @memset(self.tiles, Marks.empty);
    return self;
}

pub fn deinit(self: *Spatial, gpa: zhu.Allocator) void {
    self.mask.deinit(gpa);
    gpa.free(self.tiles);
    self.areas.clearAndFree(gpa);
}

pub fn canHoeTile(self: Spatial, position: zhu.Vector2) bool {
    const index = self.grid.worldToIndex(position) orelse return false;
    const marks = self.tiles[index];
    if (!marks.contains(.arable)) return false;
    if (marks.contains(.water)) return false;
    if (marks.contains(.occupied)) return false;
    return !self.mask.overlaps(.{ .rect = self.grid.indexToRect(index) });
}

pub fn addSolidRect(self: *Spatial, gpa: zhu.Allocator, rect: zhu.Rect) void {
    std.debug.assert(rect.size.x > 0 and rect.size.y > 0);
    self.areas.append(gpa, rect) catch zhu.oom();
}

// SolidRange 只记录对象加入 areas 时的起点和数量。
pub fn solidAreas(self: Spatial, range: SolidRange) []zhu.Rect {
    return self.areas.items[range.start..][0..range.count];
}

pub fn clearSolidRange(self: *Spatial, range: SolidRange) void {
    for (self.solidAreas(range)) |*area| area.* = .init(.zero, .zero);
}

/// 检查碰撞体放在指定位置后是否被阻挡。
pub fn isBlocked(self: Spatial, position: Vector2, collider: Shape) bool {
    const shape = collider.move(position);
    const bounds = shape.toRect();
    if (!zhu.Rect.init(.zero, self.grid.size()).contains(bounds)) return true;
    if (self.mask.overlaps(shape)) return true;

    for (self.areas.items) |area| {
        if (area.size.x <= 0 or area.size.y <= 0) continue;
        if (shape.intersect(Shape{ .rect = area })) return true;
    }
    return false;
}

/// 检查实体能否从当前位置移动到目标位置。
pub fn canMove(self: Spatial, world: *World, entity: Entity, to: zhu.Vector2) bool {
    const body = world.get(entity, Shape).?;
    if (self.isBlocked(to, body)) return false;

    const moved = body.move(to);
    var query = world.query(.{ Position, Shape, Blocking });
    while (query.next()) |row| {
        if (row.entity == entity) continue;

        const otherPosition = row.get(Position);
        const otherBody = row.get(Shape);
        const otherShape = otherBody.move(otherPosition);
        if (moved.intersect(otherShape)) return false;
    }

    return true;
}

test "isBlocked 检测碰撞框是否与 solid 格子重叠" {
    const grid = Grid{ .width = 10, .height = 12, .cell = 16 };
    var spatial = Spatial.init(std.testing.allocator, grid);
    defer spatial.deinit(std.testing.allocator);

    const collider: Shape = .{
        .rect = .init(.xy(-5, -6), .xy(10, 6)),
    };
    // 空地图不应碰撞
    try std.testing.expect(!spatial.isBlocked(.xy(24, 40), collider));

    // 标记 tile (1,2) 为 solid
    spatial.addSolidRect(std.testing.allocator, grid.indexToRect(21));
    try std.testing.expect(spatial.isBlocked(.xy(24, 40), collider));
    try std.testing.expect(!spatial.isBlocked(.xy(80, 80), collider));
}

test "isBlocked 不会把贴边当成碰撞" {
    const grid = Grid{ .width = 10, .height = 12, .cell = 16 };
    var spatial = Spatial.init(std.testing.allocator, grid);
    defer spatial.deinit(std.testing.allocator);

    spatial.addSolidRect(std.testing.allocator, grid.indexToRect(22));
    const collider: Shape = .{
        .rect = .init(.zero, .xy(10, 6)),
    };

    try std.testing.expect(!spatial.isBlocked(.xy(22, 36), collider));
    try std.testing.expect(!spatial.isBlocked(.xy(36, 26), collider));
    try std.testing.expect(spatial.isBlocked(.xy(23, 36), collider));
}

test "isBlocked 允许碰撞体贴住地图最大边界" {
    const grid = Grid{ .width = 10, .height = 12, .cell = 16 };
    var spatial = Spatial.init(std.testing.allocator, grid);
    defer spatial.deinit(std.testing.allocator);

    const collider: Shape = .{
        .rect = .init(.zero, .xy(10, 10)),
    };
    const size = spatial.grid.size();
    const position = size.sub(.xy(10, 10));

    try std.testing.expect(!spatial.isBlocked(position, collider));
}

test "isBlocked 阻挡碰撞体越过地图边界" {
    const grid = Grid{ .width = 10, .height = 12, .cell = 16 };
    var spatial = Spatial.init(std.testing.allocator, grid);
    defer spatial.deinit(std.testing.allocator);

    const collider: Shape = .{
        .rect = .init(.zero, .xy(10, 10)),
    };
    const size = spatial.grid.size();

    try std.testing.expect(spatial.isBlocked(.xy(-0.1, 0), collider));
    try std.testing.expect(spatial.isBlocked(
        .xy(size.x - 9.9, 0),
        collider,
    ));
    try std.testing.expect(spatial.isBlocked(.xy(0, -0.1), collider));
    try std.testing.expect(spatial.isBlocked(
        .xy(0, size.y - 9.9),
        collider,
    ));
}

test "对象 collider 使用精确矩形保留桌子间通道" {
    const grid = Grid{ .width = 10, .height = 12, .cell = 16 };
    var spatial = Spatial.init(std.testing.allocator, grid);
    defer spatial.deinit(std.testing.allocator);

    spatial.addSolidRect(std.testing.allocator, .init(
        .xy(83.083336, 106.208336),
        .xy(26.5, 28.25),
    ));
    spatial.addSolidRect(std.testing.allocator, .init(
        .xy(83.04163, 154.22884),
        .xy(26.5, 28.25),
    ));

    const collider: Shape = .{
        .rect = .init(.xy(-5, -6), .xy(10, 6)),
    };

    try std.testing.expect(!spatial.isBlocked(.xy(96, 144), collider));
    try std.testing.expect(spatial.isBlocked(.xy(96, 120), collider));
}

test "canHoeTile 要求可耕作且没有地图阻挡语义" {
    const grid = Grid{ .width = 10, .height = 12, .cell = 16 };
    var spatial = Spatial.init(std.testing.allocator, grid);
    defer spatial.deinit(std.testing.allocator);

    const position = zhu.Vector2.xy(24, 40);
    const index = spatial.grid.worldToIndex(position).?;

    try std.testing.expect(!spatial.canHoeTile(position));

    spatial.tiles[index].insert(.arable);
    try std.testing.expect(spatial.canHoeTile(position));

    spatial.tiles[index].insert(.water);
    try std.testing.expect(!spatial.canHoeTile(position));
    spatial.tiles[index].remove(.water);

    spatial.tiles[index].insert(.occupied);
    try std.testing.expect(!spatial.canHoeTile(position));
    spatial.tiles[index].remove(.occupied);

    spatial.mask.setCellsInRect(grid.indexToRect(index), true);
    try std.testing.expect(!spatial.canHoeTile(position));
}

test "isBlocked 圆形碰撞体检测 solid 瓦片" {
    const grid = Grid{ .width = 10, .height = 12, .cell = 16 };
    var spatial = Spatial.init(std.testing.allocator, grid);
    defer spatial.deinit(std.testing.allocator);

    const collider: Shape = .{
        .circle = .init(.xy(0, -5), 5),
    };

    // 空地图不碰撞
    try std.testing.expect(
        !spatial.isBlocked(.xy(24, 40), collider),
    );

    // solid 格子碰撞
    spatial.addSolidRect(std.testing.allocator, grid.indexToRect(21));
    try std.testing.expect(
        spatial.isBlocked(.xy(24, 40), collider),
    );
}

test "isBlocked 圆形碰撞体与区域矩形精确碰撞" {
    const grid = Grid{ .width = 10, .height = 12, .cell = 16 };
    var spatial = Spatial.init(std.testing.allocator, grid);
    defer spatial.deinit(std.testing.allocator);

    spatial.addSolidRect(std.testing.allocator, .init(.xy(83, 106), .xy(26, 28)));

    const collider: Shape = .{
        .circle = .init(.xy(0, -5), 5),
    };

    // 圆心远离矩形，不碰撞
    try std.testing.expect(!spatial.isBlocked(.xy(60, 100), collider));
    // 圆心靠近矩形左边缘，碰撞（圆心距矩形 2px，半径 5px）
    try std.testing.expect(spatial.isBlocked(.xy(78, 120), collider));
}
