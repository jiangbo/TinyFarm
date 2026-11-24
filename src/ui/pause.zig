const zhu = @import("zhu");
const ecs = @import("ecs");

const Settings = @import("../resource/Settings.zig");

const panelSize: zhu.Vector2 = .{ .x = 208, .y = 344 };
const Mode = enum { title, play };
pub const Request = enum { close, save, load, title };

var menu: zhu.widget.Menu = @import("pause.zon");

pub fn open(mode: Mode) void {
    menu.disabled = switch (mode) {
        .title => &.{ 1, 2, 3 },
        .play => &.{},
    };
    menu.position = zhu.camera.size.sub(panelSize).scale(0.5);
    menu.reset();
}

pub fn update(world: *ecs.World) ?Request {
    const event = menu.update(.{}) orelse return null;
    const settings = world.getResourcePtr(Settings).?;
    switch (event) {
        0 => return .close,
        1 => return .save, // 选择槽位后保存
        2 => return .load, // 选择槽位后读取
        3 => return .title,
        4 => settings.timeScale = @max(0.1, settings.timeScale - 0.1),
        5 => settings.timeScale += 0.1,
        6 => settings.setMusicVolume(settings.music - 0.1),
        7 => settings.setMusicVolume(settings.music + 0.1),
        8 => settings.setSoundVolume(settings.sound - 0.1),
        9 => settings.setSoundVolume(settings.sound + 0.1),
        else => unreachable,
    }
    return null;
}

pub fn draw(world: *const ecs.World) void {
    const settings = world.getResourcePtr(Settings).?;
    // 全屏覆盖
    const overlayRect = zhu.Rect.init(.zero, zhu.camera.size);
    zhu.batch.drawRect(overlayRect, .{ .color = .gray(0, 89) });

    // 暂停面板背景
    const back = zhu.Rect.init(menu.position, panelSize);
    zhu.batch.drawRect(back, .{ .color = .gray(0, 115) });

    menu.draw();

    for (0..3) |index| {
        var buffer: [40]u8 = undefined;
        const string: []const u8 = switch (index) {
            0 => zhu.format(&buffer, "Speed {d:.2}x", .{settings.timeScale}),
            1 => zhu.format(&buffer, "Music {d:.0}%", .{
                settings.music * 100,
            }),
            2 => zhu.format(&buffer, "SFX {d:.0}%", .{
                settings.sound * 100,
            }),
            else => unreachable,
        };

        const y = 212 + @as(f32, @floatFromInt(index)) * 38;
        const rect = zhu.Rect.init(.xy(24, y), .xy(160, 32));
        const pos = rect.move(menu.position).center();
        zhu.text.draw(string, pos, .{
            .anchor = .center,
        });
    }
}
