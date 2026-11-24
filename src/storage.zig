const std = @import("std");
const zhu = @import("zhu");

const component = @import("component.zig");
const Clock = @import("resource/Clock.zig");

pub const Summary = struct { day: u32 = 0, timestamp: i64 = 0 };

pub const Slot = union(enum) { empty, valid: Summary };

pub const Player = struct {
    map: component.map.Id = .town,
    position: zhu.Vector2 = .zero,
    facing: component.actor.Facing = .down,
};

pub const Inventory = struct {
    activeHotbar: usize = 0,
    activePage: usize = 0,
    slots: []const component.item.Stack = &.{},
    hotbar: []const ?usize = &.{},
};

pub const Object = union(enum) {
    gone,
    crop: component.farm.Crop,
    chest: component.item.Chest,
    product: u8,
};

pub const Tile = struct {
    index: u32 = 0,
    ground: ?component.farm.Ground = null,
    object: ?Object = null,
};

pub const Map = struct {
    day: u32 = 0,
    tiles: []Tile = &.{},
};

pub const MapRecord = struct {
    maps: std.EnumArray(component.map.Id, Map) = .initFill(.{}),

    pub fn deinit(self: MapRecord, gpa: zhu.Allocator) void {
        for (std.enums.values(component.map.Id)) |id| {
            gpa.free(self.maps.get(id).tiles);
        }
    }
};

pub const Record = struct {
    timestamp: i64 = 0,
    clock: Clock = .{},
    player: Player = .{},
    inventory: Inventory = .{},
    maps: MapRecord = .{},
    timeScale: f32 = 1,
};

pub var slots: [10]Slot = @splat(.empty);

pub fn init() void {
    slots = load(@TypeOf(slots), "saves/slots.bin", @splat(.empty));
}

pub fn read(slot: u8) !zhu.storage.Loaded(Record) {
    var buffer: [32]u8 = undefined;
    const path = zhu.formatZ(&buffer, "saves/slot{d}.bin", .{slot});
    const record = try zhu.storage.readArena(Record, path);
    std.log.info("game loaded: {s}", .{path});
    return record;
}

pub fn write(slot: u8, record: Record) !void {
    var buffer: [32]u8 = undefined;
    const path = zhu.formatZ(&buffer, "saves/slot{d}.bin", .{slot});

    try zhu.storage.writeValue(path, record);

    slots[slot] = .{ .valid = .{
        .day = record.clock.day,
        .timestamp = record.timestamp,
    } };
    try zhu.storage.writeValue("saves/slots.bin", slots);
    std.log.info("game saved: {s}", .{path});
}

fn load(T: type, path: []const u8, default: T) T {
    return zhu.storage.readValue(T, path) catch |err| switch (err) {
        error.FileNotFound => return default,
        else => std.debug.panic("load {s} failed: {}", .{ path, err }),
    };
}

test "二进制存档保留设置、背包绑定和地图对象状态" {
    var tiles = [_]Tile{
        .{ .index = 2, .ground = .wet, .object = .{ .crop = .{
            .kind = .potato,
            .stage = .growing,
            .next = 2,
            .watered = true,
        } } },
        .{ .index = 3, .object = .gone },
        .{ .index = 4, .object = .{ .chest = .{ .opened = true } } },
        .{ .index = 5, .object = .{ .product = 2 } },
        .{ .index = 6 },
    };
    var record: Record = .{
        .timestamp = 123456789,
        .timeScale = 2.5,
        .clock = .{ .day = 3, .hour = 19, .period = .night },
        .player = .{
            .map = .home_exterior,
            .position = .xy(32, 48),
            .facing = .left,
        },
        .inventory = .{
            .activeHotbar = 1,
            .slots = &.{.{ .item = .potato, .count = 7 }},
            .hotbar = &.{ null, 0 },
        },
    };
    record.maps.maps.set(.home_exterior, .{ .day = 3, .tiles = &tiles });

    const codec = zhu.codec;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try codec.encode(&output.writer, record);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: std.Io.Reader = .fixed(output.writer.buffered());
    const restored = try codec.decode(&reader, Record, arena.allocator());
    try std.testing.expectEqualDeep(record, restored);
    try std.testing.expectEqual(output.writer.buffered().len, reader.seek);
}
