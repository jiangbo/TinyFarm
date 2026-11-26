const std = @import("std");
const zhu = @import("zhu");
const ecs = @import("ecs");

const inventory = @import("inventory.zig");
const notice = @import("notice.zig");
const rest = @import("rest.zig");
const time = @import("time.zig");
const pause = @import("pause.zig");
const save = @import("save.zig");

const titleMenus: []const zhu.widget.Menu = @import("../zon/title.zon");

pub const Request = enum { block, title, load };
const Popup = enum { save, rest, pause };

var pauseButton: zhu.widget.Menu = titleMenus[1];
var activePopup: ?Popup = null;

pub fn init() void {
    inventory.reset();
    notice.init();
    time.init();
    save.init();
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

    if (zhu.action.released(.pause) or pauseButton.update(.{}) != null) {
        open(.pause);
        return .block;
    }

    inventory.update(world);
    return null;
}

fn updatePopup(world: *ecs.World, active: Popup) ?Request {
    switch (active) {
        .save => if (save.update(world)) |result| switch (result) {
            .close => close(),
            .load => return .load,
        },
        .rest => if (rest.update(world)) close(),
        .pause => if (pause.update(world)) |req| switch (req) {
            .close => close(),
            .save => {
                save.open(.save);
                activePopup = .save;
            },
            .load => {
                save.open(.load);
                activePopup = .save;
            },
            .title => return .title,
        },
    }
    return null;
}

pub fn close() void {
    activePopup = null;
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

    notice.draw(world);
}
