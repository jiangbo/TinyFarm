const std = @import("std");
const zhu = @import("zhu");

const component = @import("../component.zig");

const Map = @This();
const Allocator = std.mem.Allocator;
const AnimatedTile = struct { vertex: usize, animation: zhu.Animation };

id: component.map.Id = .school,
grid: zhu.extend.spatial.Grid = undefined,
/// 当前地图是否位于室外，进入地图时更新。
outdoor: bool = false,
vertexes: std.ArrayList(zhu.Vertex) = .empty,
animatedTiles: std.ArrayList(AnimatedTile) = .empty,
frontStart: usize = 0,

pub fn deinit(self: *Map, gpa: Allocator) void {
    self.vertexes.clearAndFree(gpa);
    self.animatedTiles.clearAndFree(gpa);
    self.frontStart = 0;
}

pub fn addImage(self: *Map, gpa: Allocator, pos: zhu.Vector2, image: zhu.Image) void {
    self.vertexes.append(gpa, .{
        .position = pos,
        .layer = image.layer,
        .size = image.size,
        .uvRect = image.uvRect(),
    }) catch zhu.oom();
}

pub fn addAnimatedTile(
    self: *Map,
    gpa: Allocator,
    position: zhu.Vector2,
    animation: zhu.Animation,
) void {
    self.animatedTiles.append(gpa, .{
        .vertex = self.vertexes.items.len,
        .animation = animation,
    }) catch zhu.oom();
    self.addImage(gpa, position, animation.subImage());
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

pub fn drawFront(self: *const Map, image: zhu.Image) void {
    const front = self.vertexes.items[self.frontStart..];
    if (front.len != 0) zhu.batch.drawVertices(image, front);
}
