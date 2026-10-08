const std = @import("std");
const Editor = @import("editor.zig").Editor;
const executor = @import("executor.zig");
const parser = @import("parser.zig");
const prompt = @import("prompt.zig");
const vars = @import("vars.zig");

fn nextContinuationLine(context: *anyopaque, arena: std.mem.Allocator) ?[]const u8 {
    const editor: *Editor = @ptrCast(@alignCast(context));
    const saved = editor.prompt;
    editor.prompt = "> ";
    defer editor.prompt = saved;
    const maybe = editor.readLine() catch return null;
    const line = maybe orelse return null;
    return arena.dupe(u8, line) catch null;
}

pub fn main() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try vars.init(allocator);
    defer vars.deinit();

    const stderr = std.io.getStdErr().writer();

    const interactive = std.io.getStdIn().isTty();
    if (interactive) executor.ignoreInteractiveSignals();

    var shell = executor.Shell{};
    var editor = Editor.init(allocator, "");
    defer editor.deinit();

    var prompt_buf: [1024]u8 = undefined;
    while (true) {
        editor.prompt = prompt.build(&prompt_buf, interactive);
        const line = try editor.readLine() orelse break;

        const input = std.mem.trim(u8, line, " \t\r");
        if (input.len == 0) continue;

        try editor.addHistory(input);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const owned_input = try arena.allocator().dupe(u8, input);
        const exit_code = shell.run(arena.allocator(), owned_input, .{ .context = &editor, .next = nextContinuationLine }) catch |err| {
            if (parser.message(err)) |text| {
                try stderr.print("zs: {s}\n", .{text});
                shell.last_status = 2;
            } else {
                try stderr.print("zs: {s}\n", .{@errorName(err)});
                shell.last_status = 1;
            }
            continue;
        };
        if (exit_code) |code| return code;
    }
    return shell.last_status;
}
