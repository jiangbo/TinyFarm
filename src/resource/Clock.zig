const component = @import("../component.zig");

pub const Period = component.time.Period;

day: u32 = 1,
hour: u8 = 6,
minute: f32 = 0.0,
period: Period = .dawn,

pub fn reset(self: *@This()) void {
    self.* = .{};
}

pub fn isDark(self: *const @This()) bool {
    return self.hour >= 18 or self.hour < 6;
}
