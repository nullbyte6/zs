const std = @import("std");

var allocator: std.mem.Allocator = undefined;
var bodies: std.StringHashMapUnmanaged([]u8) = .{};

pub fn init(gpa: std.mem.Allocator) void {
    allocator = gpa;
}

pub fn deinit() void {
    var it = bodies.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    bodies.deinit(allocator);
}

pub fn has(name: []const u8) bool {
    return bodies.contains(name);
}

pub fn get(name: []const u8) ?[]const u8 {
    return bodies.get(name);
}

pub fn names(arena: std.mem.Allocator) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(arena);
    var it = bodies.keyIterator();
    while (it.next()) |key| try list.append(key.*);
    return list.items;
}

pub fn define(name: []const u8, body: []const u8) !void {
    const copy = try allocator.dupe(u8, body);
    errdefer allocator.free(copy);
    if (bodies.getPtr(name)) |existing| {
        allocator.free(existing.*);
        existing.* = copy;
        return;
    }
    const key = try allocator.dupe(u8, name);
    errdefer allocator.free(key);
    try bodies.put(allocator, key, copy);
}

pub fn remove(name: []const u8) bool {
    const entry = bodies.fetchRemove(name) orelse return false;
    allocator.free(entry.key);
    allocator.free(entry.value);
    return true;
}
