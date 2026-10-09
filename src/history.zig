const std = @import("std");
const vars = @import("vars.zig");
const sys = @import("sys.zig");

const max_loaded = 10000;

var allocator: std.mem.Allocator = undefined;
var path: ?[]u8 = null;
pub var entries: std.ArrayList([]u8) = .empty;

pub fn init(gpa: std.mem.Allocator) void {
    allocator = gpa;
}

pub fn deinit() void {
    for (entries.items) |entry| allocator.free(entry);
    entries.deinit(allocator);
    if (path) |location| allocator.free(location);
    path = null;
}

pub fn load() void {
    const location = if (vars.get("HISTFILE")) |configured|
        allocator.dupe(u8, configured) catch return
    else blk: {
        const home = vars.get("HOME") orelse return;
        break :blk std.fmt.allocPrint(allocator, "{s}/.zs_history", .{home}) catch return;
    };
    if (path) |old| allocator.free(old);
    path = location;

    const text = sys.cwd().readFileAlloc(sys.io, location, allocator, .limited(64 << 20)) catch return;
    defer allocator.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(allocator);
    while (lines.next()) |line| {
        if (line.len > 0) all.append(allocator, line) catch return;
    }
    const start = if (all.items.len > max_loaded) all.items.len - max_loaded else 0;
    for (all.items[start..]) |line| push(line) catch return;
}

pub fn add(line: []const u8) !void {
    if (entries.getLastOrNull()) |last| {
        if (std.mem.eql(u8, last, line)) return;
    }
    try push(line);
    persist(line);
}

pub fn clear() void {
    for (entries.items) |entry| allocator.free(entry);
    entries.clearRetainingCapacity();
    const location = path orelse return;
    const file = sys.cwd().createFile(sys.io, location, .{ .truncate = true, .permissions = .fromMode(0o600) }) catch return;
    file.close(sys.io);
}

fn push(line: []const u8) !void {
    if (entries.getLastOrNull()) |last| {
        if (std.mem.eql(u8, last, line)) return;
    }
    const copy = try allocator.dupe(u8, line);
    errdefer allocator.free(copy);
    try entries.append(allocator, copy);
}

fn appendEnabled() bool {
    const setting = vars.get("HISTAPPEND") orelse return true;
    const disabled = [_][]const u8{ "0", "off", "false", "no", "never" };
    for (disabled) |word| {
        if (std.ascii.eqlIgnoreCase(setting, word)) return false;
    }
    return true;
}

fn persist(line: []const u8) void {
    if (!appendEnabled()) return;
    const location = path orelse return;
    if (std.mem.indexOfScalar(u8, line, '\n') != null) return;
    const file = sys.cwd().createFile(sys.io, location, .{ .truncate = false, .permissions = .fromMode(0o600) }) catch return;
    defer file.close(sys.io);
    const end = file.length(sys.io) catch return;
    file.writePositionalAll(sys.io, line, end) catch return;
    file.writePositionalAll(sys.io, "\n", end + line.len) catch return;
}
