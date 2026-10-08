const std = @import("std");
const posix = std.posix;
const vars = @import("vars.zig");

const fallback = " >> ";

pub fn build(buf: []u8, color: bool) []const u8 {
    var host_buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const full_host = posix.gethostname(&host_buf) catch "localhost";
    const host = full_host[0 .. std.mem.indexOfScalar(u8, full_host, '.') orelse full_host.len];
    const user = vars.get("USER") orelse "user";

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&cwd_buf) catch return fallback;

    const shown = directoryName(cwd);

    if (!color) return std.fmt.bufPrint(buf, "{s}@{s} {s}>> ", .{ user, host, shown }) catch fallback;
    return std.fmt.bufPrint(
        buf,
        "\x1b[1;32m{s}@{s}\x1b[0m \x1b[1;34m{s}\x1b[0m\x1b[1;33m>>\x1b[0m ",
        .{ user, host, shown },
    ) catch fallback;
}

fn directoryName(cwd: []const u8) []const u8 {
    if (vars.get("HOME")) |home| {
        if (home.len > 0 and std.mem.eql(u8, cwd, home)) return "~";
    }
    if (std.mem.eql(u8, cwd, "/")) return "/";
    return std.fs.path.basename(cwd);
}
