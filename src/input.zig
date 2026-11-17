const std = @import("std");
const zhu = @import("zhu");

pub const Action = enum {
    left,
    right,
    up,
    down,
    pause,
    interact,
    inventory,
    hotbar,
    hotbar1,
    hotbar2,
    hotbar3,
    hotbar4,
    hotbar5,
    hotbar6,
    hotbar7,
    hotbar8,
    hotbar9,
    hotbar10,
};

const Entry = struct { type: Action, value: []const zhu.key.Code };
const zon: []const Entry = @import("zon/input.zon");
const keys = zhu.enums.fromEntries(Entry, zon);

pub var mouseCaptured: bool = false;

pub fn held(action: Action) bool {
    return zhu.key.anyHeld(keys.get(action));
}

pub fn pressed(action: Action) bool {
    return zhu.key.anyPressed(keys.get(action));
}

pub fn released(action: Action) bool {
    return zhu.key.anyReleased(keys.get(action));
}

pub fn hotbarPressed() ?u8 {
    const first: usize = @backingInt(Action.hotbar1);
    const last: usize = @backingInt(Action.hotbar10);
    for (first..last + 1) |value| {
        const action: Action = @fromBackingInt(@intCast(value));
        if (pressed(action)) return @intCast(value - first);
    }
    return null;
}
