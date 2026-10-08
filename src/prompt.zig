const std = @import("std");
const posix = std.posix;

const fallback = " >> ";

pub fn build(buf: []u8, color: bool) []const u8 {
    var host_buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const full_host = posix.gethostname(&host_buf) catch "localhost";
    const host = full_host[0 .. std.mem.indexOfScalar(u8, full_host, '.') orelse full_host.len];
    const user = posix.getenv("USER") orelse "user";

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.process.getCwd(&cwd_buf) catch return fallback;

    var home_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const shown = abbreviateHome(&home_cwd_buf, cwd);

    if (!color) return std.fmt.bufPrint(buf, "{s}@{s} {s}>> ", .{ user, host, shown }) catch fallback;
    return std.fmt.bufPrint(
        buf,
        "\x1b[1;32m{s}@{s}\x1b[0m \x1b[1;34m{s}\x1b[0m\x1b[1;33m>>\x1b[0m ",
        .{ user, host, shown },
    ) catch fallback;
}

fn abbreviateHome(buf: []u8, cwd: []const u8) []const u8 {
    const home = posix.getenv("HOME") orelse return cwd;
    if (home.len == 0 or !std.mem.startsWith(u8, cwd, home)) return cwd;
    const rest = cwd[home.len..];
    if (rest.len != 0 and rest[0] != '/') return cwd;
    return std.fmt.bufPrint(buf, "~{s}", .{rest}) catch cwd;
}
