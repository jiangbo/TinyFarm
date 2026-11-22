const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("component.zig");
const map = @import("map.zig");
const Clock = @import("resource/Clock.zig");

const World = ecs.World;
const MapId = component.map.Id;
const Position = component.Position;
const Render = component.render.Render;
const Sprite = component.render.Sprite;
const Hidden = component.render.Hidden;
const Target = component.ui.Target;
const Player = component.actor.Player;
const Dialog = component.actor.Dialog;
const Point = component.light.Point;
const Spot = component.light.Spot;
const Disabled = component.light.Disabled;

const Keyframe = struct { hour: f32, color: zhu.Color };

// 屏幕覆盖色关键帧：只做可见昼夜色调，不模拟真实光照。
const keyframes = [_]Keyframe{
    .{ .hour = 4, .color = .rgba(10, 15, 41, 107) },
    .{ .hour = 6, .color = .rgba(173, 76, 26, 46) },
    .{ .hour = 9, .color = .rgba(0, 0, 0, 0) },
    .{ .hour = 14, .color = .rgba(0, 0, 0, 0) },
    .{ .hour = 18, .color = .rgba(204, 82, 20, 56) },
    .{ .hour = 22, .color = .rgba(8, 13, 46, 122) },
    .{ .hour = 28, .color = .rgba(10, 15, 41, 107) },
};

const clearColor: zhu.Color = .rgb(59, 79, 69);

var canvas: zhu.graphics.RenderTarget = .{};
var bubbleImage: zhu.NineImage = undefined;
var glowImage: zhu.Image = undefined;

pub fn init() void {
    canvas = zhu.graphics.createRenderTarget(zhu.camera.size, .nearest);

    const dialogImage = zhu.getImage("farm-rpg/UI/dialogue box.png").?;
    bubbleImage = zhu.NineImage.from(dialogImage, .{
        .rect = .init(.xy(0, 48), .xy(48, 48)),
        .patch = .{ .min = .xy(3, 4), .max = .xy(3, 3) },
    });
    glowImage = zhu.getImage("light.png").?;
}

pub fn deinit() void {
    canvas.deinit();
}

pub fn draw(world: *const World) void {
    zhu.batch.beginDraw(clearColor, .{ .target = &canvas });
    map.drawBack();
    drawSprites(world);
    map.drawFront();
    drawTarget(world);
    drawDialog(world);
    drawLight(world);

    zhu.batch.useTarget(clearColor, .{});
    zhu.camera.push(.window);
    defer zhu.camera.pop();
    zhu.batch.drawImage(canvas.image, .zero, .{});
}

fn drawSprites(world: *const World) void {
    const viewport = zhu.camera.mainWorldRect();
    var query = world.queryBy(Render, .{ Position, Sprite }, .{Hidden});
    while (query.next()) |row| {
        const render = row.get(Render);
        const position = row.get(Position);
        const sprite = row.get(Sprite);

        const spriteSize = sprite.size orelse sprite.image.size;
        const spritePosition = position.add(sprite.offset);
        const spriteRect = zhu.Rect.init(spritePosition, spriteSize);
        if (!viewport.intersect(spriteRect)) continue;
        zhu.batch.drawImage(sprite.image, spritePosition, .{
            .size = sprite.size,
            .color = render.color,
            .uvRect = sprite.image.uvFlip(sprite.flip, false),
        });
    }
}

fn drawTarget(world: *const World) void {
    const player = world.getIdentity(Player).?;
    const target = world.get(player, Target).?;
    if (!target.active) return;

    const rect = zhu.Rect.init(target.position, map.grid.cellSize());
    zhu.batch.drawRect(rect, .{ .color = target.color });
}

fn drawDialog(world: *const World) void {
    const entity = world.getIdentity(Dialog) orelse return;
    const dialog = world.get(entity, Dialog).?;
    if (dialog.index >= dialog.lines.len) return;

    const position = world.get(entity, Position).?;
    const head = zhu.camera.toWindow(position.addY(-24));
    zhu.camera.push(.window);
    defer zhu.camera.pop();
    drawBubble(head, dialog.lines[dialog.index]);
}

fn drawBubble(head: zhu.Vector2, text: []const u8) void {
    // head 是 NPC 头顶的窗口坐标，气泡和文字按窗口尺寸绘制。
    const option = zhu.text.Option{ .color = .black, .max = 144 };
    const textSize = zhu.text.measure(text, option);
    const size = textSize.add(.xy(16, 16)).max(.xy(160, 48));

    // 对话气泡在窗口坐标取整，避免位图文字亚像素闪烁。
    const bubblePos = head.addXY(-size.x / 2, -4 - size.y).round();
    const bubbleRect: zhu.Rect = .init(bubblePos, size);
    zhu.batch.drawNine(bubbleImage, bubbleRect);
    zhu.text.draw(text, bubbleRect.min.add(.xy(8, 8)), option);
}

fn drawLight(world: *const World) void {
    const clock = world.getResourcePtr(Clock).?;
    drawOverlay(clock.hour, clock.minute);
    drawLights(world);
}

fn drawOverlay(hourValue: u8, minute: f32) void {
    if (!isOutdoor(map.current)) return;

    const hour = @as(f32, @floatFromInt(hourValue)) + minute / 60;
    const overlay = overlayAt(hour);
    if (overlay.a == 0) return;

    zhu.batch.drawRect(zhu.camera.mainWorldRect(), .{ .color = overlay });
}

fn drawLights(world: *const World) void {
    var points = world.queryNot(.{ Position, Point }, .{Disabled});
    while (points.next()) |row| {
        const position = row.get(Position);
        const point = row.get(Point);
        const center = position.add(point.offset);
        const alpha = std.math.clamp(point.intensity, 0, 1);
        const color = point.color.scaleAlpha(0.68 * alpha);
        drawGlow(center, point.radius * 2.0, color);
    }

    // 第一版不做真实锥形，先退化成圆形占位光圈验证地图数据。
    var spots = world.queryNot(.{ Position, Spot }, .{Disabled});
    while (spots.next()) |row| {
        const pos = row.get(Position);
        const spot = row.get(Spot);
        const alpha = std.math.clamp(spot.intensity, 0, 1);
        const color = spot.color.scaleAlpha(0.56 * alpha);
        drawGlow(pos, spot.radius * 1.6, color);
    }
}

fn overlayAt(hour: f32) zhu.Color {
    const sampleHour = if (hour < 4) hour + 24 else hour;

    var i: usize = 0;
    while (i + 1 < keyframes.len) : (i += 1) {
        const left = keyframes[i];
        const right = keyframes[i + 1];
        if (sampleHour >= left.hour and sampleHour < right.hour) {
            const t = smoothStep((sampleHour - left.hour) /
                (right.hour - left.hour));
            return left.color.mix(right.color, t);
        }
    }

    return keyframes[keyframes.len - 1].color;
}

fn isOutdoor(id: MapId) bool {
    return switch (id) {
        .town, .home_exterior => true,
        .school, .home_interior => false,
    };
}

fn drawGlow(center: zhu.Vector2, size: f32, color: zhu.Color) void {
    const position = center.add(.xy(-size * 0.5, -size * 0.5));
    zhu.batch.drawImage(glowImage, position, .{
        .size = .all(size),
        .color = color,
    });
}

fn smoothStep(value: f32) f32 {
    const t = std.math.clamp(value, 0, 1);
    return t * t * (3 - 2 * t);
}

test "light overlay 正午不改变画面" {
    const color = overlayAt(12);
    try std.testing.expectEqual(0, color.a);
}

test "light overlay 深夜比白天更明显" {
    const night = overlayAt(23);
    const noon = overlayAt(12);

    try std.testing.expect(night.a > noon.a);
    try std.testing.expect(night.b > night.r);
}
