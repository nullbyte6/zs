const std = @import("std");
const Editor = @import("editor.zig").Editor;
const executor = @import("executor.zig");
const parser = @import("parser.zig");

const prompt = " >> ";

pub fn main() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stderr = std.io.getStdErr().writer();

    if (std.io.getStdIn().isTty()) executor.ignoreInteractiveSignals();

    var shell = executor.Shell{};
    var editor = Editor.init(allocator, prompt);
    defer editor.deinit();

    while (true) {
        const line = try editor.readLine() orelse break;

        const input = std.mem.trim(u8, line, " \t\r");
        if (input.len == 0) continue;

        try editor.addHistory(input);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const pipelines = parser.parse(arena.allocator(), input) catch |err| {
            try stderr.print("zs: {s}\n", .{parser.message(err)});
            shell.last_status = 2;
            continue;
        };

        const exit_code = shell.run(arena.allocator(), pipelines) catch |err| {
            try stderr.print("zs: {s}\n", .{@errorName(err)});
            shell.last_status = 1;
            continue;
        };
        if (exit_code) |code| return code;
    }
    return shell.last_status;
}
