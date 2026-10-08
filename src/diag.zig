const std = @import("std");

pub fn warning(comptime fmt: []const u8, args: anytype) void {
    emit("\x1b[33m", fmt, args);
}

pub fn failure(comptime fmt: []const u8, args: anytype) void {
    emit("\x1b[31m", fmt, args);
}

fn emit(color: []const u8, comptime fmt: []const u8, args: anytype) void {
    const file = std.io.getStdErr();
    const writer = file.writer();
    const tty = file.isTty();
    if (tty) writer.writeAll(color) catch {};
    writer.print("zs: " ++ fmt, args) catch {};
    if (tty) writer.writeAll("\x1b[0m") catch {};
    writer.writeAll("\n") catch {};
}
