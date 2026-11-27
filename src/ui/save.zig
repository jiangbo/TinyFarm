const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const save = @import("../save.zig");

const menus: []const zhu.widget.Menu = @import("save.zon");

pub const Mode = enum { load, save };
pub const Request = enum { close, load };

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

pub fn update(world: *const ecs.World) ?Request {
    if (popup.slot != null) {
        if (popup.update()) |slot| write(world, slot);
        return null;
    }

    if (menu.update(.{})) |event| {
        if (event == save.getSlots().len) return .close;

        switch (mode) {
            .load => {
                if (save.readToCache(@intCast(event))) return .load;
                menu.title.text = "读取失败";
                return null;
            },
            .save => chooseSave(world, @intCast(event)),
        }
    }
    return null;
}

pub fn draw() void {
    menu.draw();
    var buffer: [56]u8 = undefined;
    for (save.getSlots(), 0..) |slot, index| {
        const label = switch (slot) {
            .empty => "Empty",
            .valid => |summary| slotLabel(&buffer, summary),
        };
        menu.drawLabel(index, label);
    }
    popup.draw();
}

fn slotLabel(buffer: []u8, summary: save.Summary) []const u8 {
    if (summary.timestamp <= 0)
        return zhu.format(buffer, "Day {d}", .{summary.day});

    const nanos = @as(i96, summary.timestamp) * std.time.ns_per_s;
    const date = zhu.localTime(.fromNanoseconds(nanos));
    const fmt = "Day {d} - {d:0>2}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}";
    return zhu.format(buffer, fmt, .{
        summary.day,    @abs(@mod(date.year, 100)), @abs(date.month),
        @abs(date.day), @abs(date.hour),            @abs(date.minute),
    });
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

fn chooseSave(world: *const ecs.World, slot: u8) void {
    switch (save.getSlots()[slot]) {
        .empty => write(world, slot),
        .valid => popup.slot = slot,
    }
}

fn write(world: *const ecs.World, slot: u8) void {
    menu.title.text = if (save.write(world, slot)) "保存成功" else "保存失败";
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
