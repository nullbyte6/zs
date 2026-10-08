const std = @import("std");

const prompt = " >> ";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var line: std.ArrayList(u8) = .init(allocator);
    defer line.deinit();

    while (true) {
        try stdout.writeAll(prompt);

        line.clearRetainingCapacity();
        stdin.streamUntilDelimiter(line.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => {
                try stdout.writeAll("\n");
                break;
            },
            else => return err,
        };

        const input = std.mem.trim(u8, line.items, " \t\r");
        if (input.len == 0) continue;

        if (std.mem.eql(u8, input, "exit")) break;

        try stdout.print("zs: command execution not implemented: {s}\n", .{input});
    }
}
