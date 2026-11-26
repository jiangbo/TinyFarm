const std = @import("std");
const zhu = @import("zhu");

const save = @import("../save.zig");

const menus: []const zhu.widget.Menu = @import("save.zon");

pub const Mode = enum { load, save };
pub const Request = union(enum) { close, save: u8, load: u8 };

var mode: Mode = .load;
var disabledBuffer: [menus[0].buttons.len]usize = undefined;
var disabled: std.ArrayList(usize) = .initBuffer(&disabledBuffer);
var menu: zhu.widget.Menu = menus[0];

pub fn init() void {
    menu.centerInWindow();
    popup.popupMenu.centerInWindow();
}

pub fn open(next: Mode) void {
    mode = next;
    popup.slot = null;

    menu.disabled = &.{};
    switch (mode) {
        .load => openLoad(),
        .save => menu.title.text = "Save Game",
    }
}

pub fn update() ?Request {
    if (popup.slot != null) {
        if (popup.update()) |slot| return .{ .save = slot };
        return null;
    }

    if (menu.update(.{})) |event| {
        if (event == save.getSlots().len) return .close;

        return switch (mode) {
            .load => .{ .load = @intCast(event) },
            .save => chooseSave(event),
        };
    }
    return null;
}

pub fn draw() void {
    menu.draw();
    var buffer: [56]u8 = undefined;
    for (save.getSlots(), 0..) |slot, index| {
        const label = switch (slot) {
            .empty => zhu.format(&buffer, "Slot {d} Empty", .{index + 1}),
            .valid => |summary| zhu.format(&buffer, "Slot {d} Day {d}", .{
                index + 1, summary.day,
            }),
        };
        menu.drawLabel(index, label);
    }
    popup.draw();
}

fn openLoad() void {
    disabled.clearRetainingCapacity();
    for (save.getSlots(), 0..) |slot, index| switch (slot) {
        .valid => {},
        .empty => disabled.appendAssumeCapacity(index),
    };
    menu.disabled = disabled.items;
    menu.title.text = "Load Game";
}

fn chooseSave(slot: usize) ?Request {
    switch (save.getSlots()[slot]) {
        .empty => return .{ .save = @intCast(slot) },
        .valid => popup.slot = @intCast(slot),
    }
    return null;
}

const popup = struct {
    var slot: ?u8 = null;
    var popupMenu: zhu.widget.Menu = menus[1];

    fn update() ?u8 {
        const current = slot orelse return null;

        if (popupMenu.update(.{})) |event| {
            slot = null;
            if (event == 0) return current;
            if (event == 1) return null;
            unreachable;
        }
        return null;
    }

    fn draw() void {
        const current = slot orelse return;

        var buffer: [40]u8 = undefined;
        var copy = popupMenu;
        const fmt = "Overwrite slot {d}?";
        copy.title.text = zhu.format(&buffer, fmt, .{current + 1});
        copy.draw();
    }
};
