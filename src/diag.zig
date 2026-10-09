const std = @import("std");
const sys = @import("sys.zig");

pub fn warning(comptime fmt: []const u8, args: anytype) void {
    emit("\x1b[33m", fmt, args);
}

pub fn failure(comptime fmt: []const u8, args: anytype) void {
    emit("\x1b[31m", fmt, args);
}

fn emit(color: []const u8, comptime fmt: []const u8, args: anytype) void {
    const file = sys.stderr();
    const tty = sys.isTty(file);
    if (tty) sys.writeAll(file, color) catch {};
    sys.print(file, "zs: " ++ fmt, args) catch {};
    if (tty) sys.writeAll(file, "\x1b[0m") catch {};
    sys.writeAll(file, "\n") catch {};
}
