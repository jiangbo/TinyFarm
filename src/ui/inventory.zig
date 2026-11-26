const zhu = @import("zhu");
const ecs = @import("ecs");

const factory = @import("../factory.zig");
const item = @import("item.zig");
const drag = @import("drag.zig");
const bag = @import("bag.zig");
const bar = @import("bar.zig");
const Inventory = @import("../resource/Inventory.zig");
const Notice = @import("../resource/Notice.zig");

const ItemEnum = @import("../component.zig").item.ItemEnum;
const World = ecs.World;

pub fn reset() void {
    bag.reset();
    bar.reset();
    drag.reset();
}

pub fn update(world: *const World) void {
    const inventory = world.getResourcePtr(Inventory).?;
    const notice = world.getResourcePtr(Notice).?;

    const bagCaptured = bag.update(inventory);
    if (bag.drag != null) return;

    const rightClick = !drag.active() and zhu.key.pressed(.MOUSE_RIGHT);
    if (rightClick and updateUseItem(inventory, notice, bagCaptured)) return;

    if (!bagCaptured) bar.update(inventory);
    const canDrag = !bagCaptured or bag.hover(inventory.activePage) != null;
    drag.update(inventory, canDrag);
    if (rightClick and !zhu.mouse.captured) inventory.activeHotbar = null;
}

pub fn draw(world: *const World) void {
    const inventory = world.getResourcePtr(Inventory).?;

    bag.draw(inventory, drag.hiddenBag());
    bar.draw(inventory, drag.hiddenBar());
    drag.draw();
    const itemType = tooltipItem(inventory) orelse return;
    item.drawTooltip(itemType);
}

fn updateUseItem(inventory: *Inventory, notice: *Notice, bagCaptured: bool) bool {
    const slot: ?usize = if (bag.hover(inventory.activePage)) |bagIndex|
        bagIndex
    else if (bagCaptured)
        return false
    else if (bar.hover()) |barIndex|
        inventory.hotbar[barIndex]
    else
        return false;

    zhu.mouse.captured = true;
    const index = slot orelse return true;
    switch (inventory.useAt(index)) {
        .none => {},
        .full => notice.show("背包已满", .{}),
        .item => |value| notice.show("获得 {s} x{d}", .{
            factory.itemConfig(value.item).name,
            value.count,
        }),
    }
    return true;
}

fn tooltipItem(inventory: *Inventory) ?ItemEnum {
    if (drag.active() or bag.drag != null) return null;

    if (bag.hover(inventory.activePage)) |index| {
        const slot = inventory.store.getPtr(index) orelse return null;
        return slot.item;
    }

    const barIndex = bar.hover() orelse return null;
    const bagIndex = inventory.hotbar[barIndex] orelse return null;
    const slot = inventory.store.getPtr(bagIndex) orelse return null;
    return slot.item;
}
