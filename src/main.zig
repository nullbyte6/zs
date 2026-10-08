const std = @import("std");
const Editor = @import("editor.zig").Editor;

const prompt = " >> ";

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    var editor = Editor.init(allocator, prompt);
    defer editor.deinit();

    while (true) {
        const line = try editor.readLine() orelse break;

        const input = std.mem.trim(u8, line, " \t\r");
        if (input.len == 0) continue;

        try editor.addHistory(input);

        if (std.mem.eql(u8, input, "exit")) break;

        try stdout.print("zs: command execution not implemented: {s}\n", .{input});
    }
}
