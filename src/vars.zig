const std = @import("std");

pub const Assignment = struct {
    name: []const u8,
    value: []const u8,
};

var allocator: std.mem.Allocator = undefined;
var values: std.StringHashMapUnmanaged([]u8) = .{};
var exported: std.StringHashMapUnmanaged(void) = .{};

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
