const std = @import("std");
const zhu = @import("zhu");

const Settings = @This();
const Global = struct { music: f32 = 1, sound: f32 = 1 };

music: f32 = 1,
sound: f32 = 1,
/// 游戏内时钟的推进倍率，1 表示正常速度。
timeScale: f32 = 1,
/// 随身灯的手动开关，实际亮灭由灯光系统决定。
lightOn: bool = false,

pub fn load() Settings {
    const global = zhu.storage.readValue(Global, "settings.bin") catch Global{};
    zhu.music.setVolume(global.music);
    zhu.sound.setVolume(global.sound);
    return .{ .music = global.music, .sound = global.sound };
}

pub fn setMusicVolume(self: *Settings, volume: f32) void {
    const next = zhu.clamp(volume, 0, 1);
    if (self.music == next) return;
    self.music = next;
    zhu.music.setVolume(self.music);
    self.save();
}

pub fn setSoundVolume(self: *Settings, volume: f32) void {
    const next = zhu.clamp(volume, 0, 1);
    if (self.sound == next) return;
    self.sound = next;
    zhu.sound.setVolume(self.sound);
    self.save();
}

fn save(self: *const Settings) void {
    const global: Global = .{ .music = self.music, .sound = self.sound };
    zhu.storage.writeValue("settings.bin", global) catch |err| {
        std.log.err("save settings failed: {}", .{err});
    };
}
