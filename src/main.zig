const std = @import("std");
const Editor = @import("editor.zig").Editor;
const executor = @import("executor.zig");
const functions = @import("functions.zig");
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

fn renderPrompt(shell: *executor.Shell, arena: std.mem.Allocator, color: bool) []const u8 {
    const rendered = prompt.render(arena, prompt.format(), color, shell.last_status) catch return "zs>> ";
    return shell.expandText(arena, rendered);
}

pub fn main() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try vars.init(allocator);
    defer vars.deinit();
    functions.init(allocator);
    defer functions.deinit();
    prompt.init(allocator);
    defer prompt.deinit();

    const stderr = std.io.getStdErr().writer();

    const interactive = std.io.getStdIn().isTty();
    if (interactive) executor.ignoreInteractiveSignals();

    var shell = executor.Shell{};
    var editor = Editor.init(allocator, "");
    defer editor.deinit();

    while (true) {
        var prompt_arena = std.heap.ArenaAllocator.init(allocator);
        defer prompt_arena.deinit();
        editor.prompt = renderPrompt(&shell, prompt_arena.allocator(), interactive);
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
