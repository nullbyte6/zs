const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const vars = @import("vars.zig");
const functions = @import("functions.zig");
const aliases = @import("aliases.zig");

pub const builtins = [_][]const u8{ "cd", "exit", "export", "unset", "break", "continue", "read", "local", "return", "shift", "zsprompt", "source", ".", "set", ":", "exec", "history", "alias", "unalias" };

pub fn exists(name: []const u8) bool {
    if (name.len == 0) return false;
    if (functions.has(name)) return true;
    if (aliases.has(name)) return true;
    for (builtins) |builtin| {
        if (std.mem.eql(u8, builtin, name)) return true;
    }

    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = expandHome(&home_buf, name) orelse name;
    if (std.mem.indexOfScalar(u8, resolved, '/') != null) return isExecutable(resolved);

    const path = vars.get("PATH") orelse return false;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        const candidate = std.fmt.bufPrint(&buf, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch continue;
        if (isExecutable(candidate)) return true;
    }
    return false;
}

fn expandHome(buf: []u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "~/")) return null;
    const home = vars.get("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ home, name[1..] }) catch null;
}

fn isExecutable(path: []const u8) bool {
    const stat = sys.cwd().statFile(sys.io, path, .{}) catch return false;
    if (stat.kind != .file) return false;
    sys.access(path, posix.X_OK) catch return false;
    return true;
}
