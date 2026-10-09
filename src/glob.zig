const std = @import("std");
const sys = @import("sys.zig");

pub fn expand(arena: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
    const absolute = pattern.len > 0 and pattern[0] == '/';
    var prefixes: std.ArrayList([]const u8) = .empty;
    try prefixes.append(arena, if (absolute) "/" else "");

    var segments = std.mem.tokenizeScalar(u8, pattern, '/');
    while (segments.next()) |segment| {
        var results: std.ArrayList([]const u8) = .empty;
        if (!hasWildcard(segment)) {
            const literal = try unescape(arena, segment);
            for (prefixes.items) |prefix| try results.append(arena, try join(arena, prefix, literal));
        } else {
            for (prefixes.items) |prefix| try collect(arena, prefix, segment, &results);
        }
        prefixes = results;
        if (prefixes.items.len == 0) break;
    }

    const trailing_slash = pattern.len > 1 and pattern[pattern.len - 1] == '/';
    var matches: std.ArrayList([]const u8) = .empty;
    for (prefixes.items) |path| {
        const full = if (trailing_slash) try std.fmt.allocPrint(arena, "{s}/", .{path}) else path;
        sys.cwd().access(sys.io, full, .{}) catch continue;
        try matches.append(arena, full);
    }
    return matches.items;
}

fn collect(arena: std.mem.Allocator, prefix: []const u8, segment: []const u8, results: *std.ArrayList([]const u8)) !void {
    var dir = sys.cwd().openDir(sys.io, if (prefix.len == 0) "." else prefix, .{ .iterate = true }) catch return;
    defer dir.close(sys.io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(sys.io) catch null) |entry| {
        if (entry.name[0] == '.' and segment[0] != '.') continue;
        if (match(segment, entry.name)) try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| try results.append(arena, try join(arena, prefix, name));
}

fn join(arena: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return arena.dupe(u8, name);
    if (std.mem.eql(u8, prefix, "/")) return std.fmt.allocPrint(arena, "/{s}", .{name});
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn hasWildcard(segment: []const u8) bool {
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        switch (segment[i]) {
            '*', '?', '[' => return true,
            '\\' => i += 1,
            else => {},
        }
    }
    return false;
}

fn unescape(arena: std.mem.Allocator, segment: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        if (segment[i] == '\\' and i + 1 < segment.len) i += 1;
        try out.append(arena, segment[i]);
    }
    return out.items;
}

pub fn match(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star: ?usize = null;
    var star_ni: usize = 0;
    while (ni < name.len) {
        var advanced = false;
        if (pi < pattern.len) {
            switch (pattern[pi]) {
                '*' => {
                    star = pi;
                    star_ni = ni;
                    pi += 1;
                    continue;
                },
                '?' => {
                    ni += std.unicode.utf8ByteSequenceLength(name[ni]) catch 1;
                    pi += 1;
                    advanced = true;
                },
                '[' => if (matchClass(pattern, pi, name[ni])) |class| {
                    if (class.matched) {
                        ni += 1;
                        pi = class.end;
                        advanced = true;
                    }
                } else if (name[ni] == '[') {
                    ni += 1;
                    pi += 1;
                    advanced = true;
                },
                '\\' => {
                    const literal = if (pi + 1 < pattern.len) pattern[pi + 1] else '\\';
                    if (name[ni] == literal) {
                        ni += 1;
                        pi += if (pi + 1 < pattern.len) 2 else 1;
                        advanced = true;
                    }
                },
                else => if (pattern[pi] == name[ni]) {
                    ni += 1;
                    pi += 1;
                    advanced = true;
                },
            }
        }
        if (advanced) continue;
        const s = star orelse return false;
        pi = s + 1;
        star_ni += 1;
        ni = star_ni;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

const Class = struct { matched: bool, end: usize };

fn matchClass(pattern: []const u8, start: usize, ch: u8) ?Class {
    var i = start + 1;
    var negate = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pattern.len) {
        if (pattern[i] == ']' and !first) return .{ .matched = matched != negate, .end = i + 1 };
        first = false;
        var lo = pattern[i];
        if (lo == '\\' and i + 1 < pattern.len) {
            i += 1;
            lo = pattern[i];
        }
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            if (ch >= lo and ch <= pattern[i + 2]) matched = true;
            i += 3;
        } else {
            if (ch == lo) matched = true;
            i += 1;
        }
    }
    return null;
}
