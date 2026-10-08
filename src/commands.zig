const std = @import("std");
const posix = std.posix;

pub const builtins = [_][]const u8{"exit"};

pub fn exists(name: []const u8) bool {
    if (name.len == 0) return false;
    for (builtins) |builtin| {
        if (std.mem.eql(u8, builtin, name)) return true;
    }
    if (std.mem.indexOfScalar(u8, name, '/') != null) return isExecutable(name);

    const path = posix.getenv("PATH") orelse return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        const candidate = std.fmt.bufPrint(&buf, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch continue;
        if (isExecutable(candidate)) return true;
    }
    return false;
}

fn isExecutable(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    if (stat.kind != .file) return false;
    posix.access(path, posix.X_OK) catch return false;
    return true;
}
