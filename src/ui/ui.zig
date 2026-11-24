const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const input = @import("../input.zig");
const inventory = @import("inventory.zig");
const notice = @import("notice.zig");
const rest = @import("rest.zig");
const time = @import("time.zig");
const pause = @import("pause.zig");
const save = @import("save.zig");

const titleMenus: []const zhu.widget.Menu = @import("../zon/title.zon");

pub const Message = struct { text: []const u8, fail: bool };
pub const Request = union(enum) {
    block,
    title,
    save: u8,
    load: u8,
};
const Popup = enum { save, rest, pause };

var pauseButton: zhu.widget.Menu = titleMenus[1];
var activePopup: ?Popup = null;
var popupMessage: ?Message = null;

pub fn init(slots: []const save.Slot) void {
    inventory.reset();
    notice.init();
    time.init();
    save.init(slots);
    rest.init();
    const size = pauseButton.buttons[0].shape.toRect().size;
    pauseButton.position = .xy(zhu.camera.size.x - 10 - size.x, 10);
}

pub fn deinit() void {}

pub fn resetInventory() void {
    inventory.reset();
}

pub fn open(next: enum { pause, rest }) void {
    switch (next) {
        .pause => {
            pause.open(.play);
            activePopup = .pause;
        },
        .rest => {
            rest.hours = 8;
            activePopup = .rest;
        },
    }
}

pub fn update(world: *ecs.World, delta: f32) ?Request {
    notice.update(world, delta);

    if (activePopup) |active| {
        if (updatePopup(world, active)) |req| return req;
        return .block;
    }

    const mouse = zhu.mouse.pos.sub(pauseButton.position);
    const button = pauseButton.buttons[0].shape.toRect();
    if (button.contains(mouse) or pauseButton.pressed != null) {
        zhu.mouse.captured = true;
    }

    if (input.released(.pause) or pauseButton.update(.{}) != null) {
        open(.pause);
        return .block;
    }

    inventory.update(world);
    return null;
}

fn updatePopup(world: *ecs.World, active: Popup) ?Request {
    switch (active) {
        .save => {
            if (save.update()) |result| {
                switch (result) {
                    .close => close(),
                    .save => |slot| {
                        activePopup = .pause;
                        return .{ .save = slot };
                    },
                    .load => |slot| {
                        activePopup = .pause;
                        return .{ .load = slot };
                    },
                }
            }
        },
        .rest => if (rest.update(world)) close(),
        .pause => if (pause.update(world)) |req| switch (req) {
            .close => close(),
            .save => {
                popupMessage = null;
                save.open(.save);
                activePopup = .save;
            },
            .load => {
                popupMessage = null;
                save.open(.load);
                activePopup = .save;
            },
            .title => return .title,
        },
    }
    return null;
}

pub fn showMessage(next: Message) void {
    popupMessage = next;
}

pub fn close() void {
    activePopup = null;
    popupMessage = null;
}

pub fn draw(world: *const ecs.World) void {
    time.draw(world);
    pauseButton.draw();
    inventory.draw(world);

    if (activePopup) |active| {
        switch (active) {
            .save => save.draw(),
            .rest => rest.draw(),
            .pause => pause.draw(world),
        }
    }

    if (popupMessage) |current| {
        var color = zhu.Color.rgb(64, 255, 64);
        if (current.fail) color = .rgb(255, 64, 64);
        zhu.text.draw(current.text, .xy(zhu.camera.size.x * 0.5, 32), .{
            .anchor = .center,
            .color = color,
        });
    }

    notice.draw(world);
}
