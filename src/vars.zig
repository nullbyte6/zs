const std = @import("std");

pub const Assignment = struct {
    name: []const u8,
    value: []const u8,
};

var allocator: std.mem.Allocator = undefined;
var values: std.StringHashMapUnmanaged([]u8) = .{};
var exported: std.StringHashMapUnmanaged(void) = .{};

const Saved = struct {
    name: []u8,
    value: ?[]u8,
    exported: bool,
};

const Frame = struct {
    params: std.ArrayListUnmanaged([]u8) = .{},
    saved: std.ArrayListUnmanaged(Saved) = .{},
};

var frames: std.ArrayListUnmanaged(Frame) = .{};

pub fn init(gpa: std.mem.Allocator) !void {
    allocator = gpa;
    for (std.os.environ) |entry_z| {
        const entry = std.mem.span(entry_z);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        try set(entry[0..eq], entry[eq + 1 ..]);
        try markExported(entry[0..eq]);
    }
}

pub fn deinit() void {
    var value_it = values.iterator();
    while (value_it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    values.deinit(allocator);
    var export_it = exported.keyIterator();
    while (export_it.next()) |key| allocator.free(key.*);
    exported.deinit(allocator);
    frames.deinit(allocator);
}

pub fn get(name: []const u8) ?[]const u8 {
    return values.get(name);
}

pub fn set(name: []const u8, value: []const u8) !void {
    const copy = try allocator.dupe(u8, value);
    errdefer allocator.free(copy);
    if (values.getPtr(name)) |existing| {
        allocator.free(existing.*);
        existing.* = copy;
        return;
    }
    const key = try allocator.dupe(u8, name);
    errdefer allocator.free(key);
    try values.put(allocator, key, copy);
}

pub fn markExported(name: []const u8) !void {
    if (exported.contains(name)) return;
    const key = try allocator.dupe(u8, name);
    errdefer allocator.free(key);
    try exported.put(allocator, key, {});
}

pub fn unset(name: []const u8) void {
    if (values.fetchRemove(name)) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
    if (exported.fetchRemove(name)) |entry| allocator.free(entry.key);
}

pub fn exportedNames(arena: std.mem.Allocator) ![][]const u8 {
    var names = std.ArrayList([]const u8).init(arena);
    var it = exported.keyIterator();
    while (it.next()) |key| {
        if (values.contains(key.*)) try names.append(key.*);
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

pub fn environ(arena: std.mem.Allocator, overlay: []const Assignment) ![:null]?[*:0]const u8 {
    var entries = std.ArrayList(?[*:0]const u8).init(arena);
    var it = exported.keyIterator();
    while (it.next()) |key| {
        if (isOverlaid(overlay, key.*)) continue;
        const value = values.get(key.*) orelse continue;
        try entries.append((try std.fmt.allocPrintZ(arena, "{s}={s}", .{ key.*, value })).ptr);
    }
    for (overlay) |assignment| {
        try entries.append((try std.fmt.allocPrintZ(arena, "{s}={s}", .{ assignment.name, assignment.value })).ptr);
    }
    const result = try arena.allocSentinel(?[*:0]const u8, entries.items.len, null);
    @memcpy(result, entries.items);
    return result;
}

fn isOverlaid(overlay: []const Assignment, name: []const u8) bool {
    for (overlay) |assignment| {
        if (std.mem.eql(u8, assignment.name, name)) return true;
    }
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn pushFrame(args: []const []const u8) !void {
    var frame = Frame{};
    errdefer freeFrame(&frame);
    for (args) |arg| try frame.params.append(allocator, try allocator.dupe(u8, arg));
    try frames.append(allocator, frame);
}

pub fn popFrame() void {
    var frame = frames.pop() orelse return;
    var index = frame.saved.items.len;
    while (index > 0) : (index -= 1) {
        const entry = frame.saved.items[index - 1];
        if (entry.value) |old| {
            set(entry.name, old) catch {};
            if (entry.exported) markExported(entry.name) catch {};
        } else {
            unset(entry.name);
        }
    }
    freeFrame(&frame);
}

fn freeFrame(frame: *Frame) void {
    for (frame.params.items) |param| allocator.free(param);
    frame.params.deinit(allocator);
    for (frame.saved.items) |entry| {
        allocator.free(entry.name);
        if (entry.value) |value| allocator.free(value);
    }
    frame.saved.deinit(allocator);
}

pub fn inFunction() bool {
    return frames.items.len > 0;
}

pub fn declareLocal(name: []const u8) !void {
    if (frames.items.len == 0) return;
    const frame = &frames.items[frames.items.len - 1];
    for (frame.saved.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return;
    }
    const key = try allocator.dupe(u8, name);
    errdefer allocator.free(key);
    const old: ?[]u8 = if (values.get(name)) |value| try allocator.dupe(u8, value) else null;
    errdefer if (old) |value| allocator.free(value);
    try frame.saved.append(allocator, .{ .name = key, .value = old, .exported = exported.contains(name) });
    unset(name);
}
