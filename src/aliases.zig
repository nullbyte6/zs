const std = @import("std");

var allocator: std.mem.Allocator = undefined;
var values: std.StringHashMapUnmanaged([]u8) = .{};

pub fn init(gpa: std.mem.Allocator) void {
    allocator = gpa;
}

pub fn deinit() void {
    var it = values.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    values.deinit(allocator);
}

pub fn has(name: []const u8) bool {
    return values.contains(name);
}

pub fn get(name: []const u8) ?[]const u8 {
    return values.get(name);
}

pub fn names(arena: std.mem.Allocator) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(arena);
    var it = values.keyIterator();
    while (it.next()) |key| try list.append(key.*);
    std.mem.sort([]const u8, list.items, {}, lessThan);
    return list.items;
}

pub fn define(name: []const u8, value: []const u8) !void {
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

pub fn remove(name: []const u8) bool {
    const entry = values.fetchRemove(name) orelse return false;
    allocator.free(entry.key);
    allocator.free(entry.value);
    return true;
}

pub fn clear() void {
    var it = values.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    values.clearRetainingCapacity();
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
