const zhu = @import("zhu");

pub const Action = zhu.enums.fromField(@import("zon/input.zon"), "type");

const Entry = struct { type: Action, value: []const zhu.key.Code };
const zon: []const Entry = @import("zon/input.zon");
const keys = zhu.enums.fromEntries(Entry, zon);

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
    for ([_]Action{
        .hotbar1, .hotbar2, .hotbar3, .hotbar4, .hotbar5,
        .hotbar6, .hotbar7, .hotbar8, .hotbar9, .hotbar10,
    }, 0..) |action, index| {
        if (pressed(action)) return @intCast(index);
    }
    return null;
}
