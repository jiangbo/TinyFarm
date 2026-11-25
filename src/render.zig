const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const component = @import("component.zig");
const map = @import("map.zig");
const Clock = @import("resource/Clock.zig");
const Map = @import("resource/Map.zig");

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
const Emissive = component.light.Emissive;
const Enabled = component.light.Enabled;

const Keyframe = struct { hour: f32, color: zhu.Color };

// 环境光关键帧（乘法光照图底色，正午为纯白原色）。
const keyframes = [_]Keyframe{
    .{ .hour = 4, .color = .rgb(38, 42, 72) },
    .{ .hour = 6, .color = .rgb(190, 145, 115) },
    .{ .hour = 9, .color = .rgb(245, 240, 230) },
    .{ .hour = 14, .color = .rgb(255, 255, 255) },
    .{ .hour = 18, .color = .rgb(220, 140, 95) },
    .{ .hour = 22, .color = .rgb(38, 42, 72) },
    .{ .hour = 28, .color = .rgb(38, 42, 72) },
};

const clearColor: zhu.Color = .rgb(59, 79, 69);

var canvas: zhu.graphics.RenderTarget = .{};
var lightCanvas: zhu.graphics.RenderTarget = .{};
var bubbleImage: zhu.NineImage = undefined;
var glowImage: zhu.Image = undefined;
var spotImage: zhu.Image = undefined;
var mapImage: zhu.Image = undefined;
var dryLandImage: zhu.Image = undefined;
var wetLandImage: zhu.Image = undefined;

pub fn init() void {
    canvas = zhu.graphics.createRenderTarget(zhu.camera.size, .nearest);
    lightCanvas = zhu.graphics.createRenderTarget(zhu.camera.size, .nearest);
    const mul = zhu.graphics.createQuadPipeline(.multiply);
    zhu.assets.gpu.putView(lightCanvas.image.view, mul);

    const dialogImage = zhu.getImage("farm-rpg/UI/dialogue box.png").?;
    bubbleImage = zhu.NineImage.from(dialogImage, .{
        .rect = .init(.xy(0, 48), .xy(48, 48)),
        .patch = .{ .min = .xy(3, 4), .max = .xy(3, 3) },
    });
    glowImage = zhu.getImage("light.png").?;
    spotImage = zhu.getImage("spot.png").?;
    mapImage = zhu.getImage("circle.png").?;
    const land = zhu.getImage(
        "farm-rpg/Farm/Tileset/Modular/Tilled Soil and wet soil.png",
    ).?;
    dryLandImage = land.sub(.init(.xy(0, 48), .xy(16, 16)));
    wetLandImage = land.sub(.init(.xy(192, 48), .xy(16, 16)));
}

pub fn deinit() void {
    canvas.deinit();
    lightCanvas.deinit();
}

pub fn draw(world: *const World) void {
    const clock = world.getResourcePtr(Clock).?;
    const current = world.getResourcePtr(Map).?;
    const ambient = ambientColor(current.id, clock, current.outdoor);
    zhu.batch.beginDraw(ambient, .{ .target = &lightCanvas });
    drawLights(world);

    zhu.batch.useTarget(clearColor, .{ .target = &canvas });
    current.drawBack(mapImage);
    current.drawGround(dryLandImage, wetLandImage);
    drawSprites(world);
    current.drawFront(mapImage);
    drawTarget(world, current.grid.cellSize());
    // 对比过不参与光照的效果，确认保留对话气泡参与光照合成。
    drawDialog(world);
    zhu.batch.drawCamera(lightCanvas.image, .zero, .window, .{});
    drawEmissive(world);

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

fn drawTarget(world: *const World, cellSize: zhu.Vector2) void {
    const player = world.getIdentity(Player).?;
    const target = world.get(player, Target).?;
    if (!target.active) return;

    const rect = zhu.Rect.init(target.position, cellSize);
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

fn drawLights(world: *const World) void {
    var points = world.query(.{ Position, Point, Enabled });
    while (points.next()) |row| {
        const position = row.get(Position);
        const point = row.get(Point);
        const center = position.add(point.offset);
        const alpha = std.math.clamp(point.intensity, 0, 1);
        drawGlow(center, point.radius * 2.0, point.color.scaleAlpha(alpha));
    }

    var spots = world.query(.{ Position, Spot, Enabled });
    while (spots.next()) |row| {
        const pos = row.get(Position);
        const spot = row.get(Spot);
        const alpha = std.math.clamp(spot.intensity, 0, 1);
        zhu.batch.drawImage(spotImage, pos, .{
            .size = .all(spot.radius * 2.0),
            .anchor = .center,
            .pivot = .center,
            .radian = spot.direction.atan2(),
            .color = .all(0),
            .addColor = spot.color.scaleAlpha(alpha),
        });
    }
}

fn drawEmissive(world: *const World) void {
    var query = world.query(.{ Position, Emissive, Enabled });
    while (query.next()) |row| {
        const pos = row.get(Position);
        const em = row.get(Emissive);
        const alpha = std.math.clamp(em.intensity, 0, 1);
        zhu.batch.drawImage(zhu.batch.whiteImage, pos, .{
            .size = em.size,
            .color = .all(0),
            .addColor = em.color.scaleAlpha(alpha),
        });
        const center = pos.add(.xy(em.size.x * 0.5, em.size.y * 0.5));
        const glowSize = @max(em.size.x, em.size.y) + 22;
        drawGlow(center, glowSize, em.color.scaleAlpha(alpha * 0.35));
    }
}

fn ambientColor(id: MapId, clock: *const Clock, outdoor: bool) zhu.Color {
    if (!outdoor) {
        const data = map.maps[@backingInt(id)];
        const ambient = data.getClass("ambient") orelse return .white;
        return .fromFloat(.{
            .r = ambient.get("red", f32) orelse 1,
            .g = ambient.get("green", f32) orelse 1,
            .b = ambient.get("blue", f32) orelse 1,
            .a = 1,
        });
    }
    const hour = @as(f32, @floatFromInt(clock.hour)) + clock.minute / 60;
    return ambientAt(hour);
}

fn ambientAt(hour: f32) zhu.Color {
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

fn drawGlow(center: zhu.Vector2, size: f32, color: zhu.Color) void {
    const position = center.add(.xy(-size * 0.5, -size * 0.5));
    zhu.batch.drawImage(glowImage, position, .{
        .size = .all(size),
        .color = .all(0),
        .addColor = color,
    });
}

fn smoothStep(value: f32) f32 {
    const t = std.math.clamp(value, 0, 1);
    return t * t * (3 - 2 * t);
}
