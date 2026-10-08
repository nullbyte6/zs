const std = @import("std");
const arith = @import("arith.zig");
const Editor = @import("editor.zig").Editor;
const executor = @import("executor.zig");
const functions = @import("functions.zig");
const history = @import("history.zig");
const parser = @import("parser.zig");
const prompt = @import("prompt.zig");
const rc = @import("rc.zig");
const spec = @import("spec.zig");
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

fn supportsPromptMarks() bool {
    const term = vars.get("TERM") orelse return false;
    return term.len > 0 and !std.mem.eql(u8, term, "dumb") and !std.mem.eql(u8, term, "linux");
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
    history.init(allocator);
    defer history.deinit();
    spec.init(allocator);
    defer spec.deinit();

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var command: ?[]const u8 = null;
    var force_interactive = false;
    var login = argv.len > 0 and argv[0].len > 0 and argv[0][0] == '-';
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "--login")) {
            login = true;
            continue;
        }
        for (arg[1..]) |flag| switch (flag) {
            'c' => {
                index += 1;
                if (index >= argv.len) {
                    try stderr.writeAll("zs: -c: option requires an argument\n");
                    return 2;
                }
                command = argv[index];
            },
            'i' => force_interactive = true,
            'l' => login = true,
            's' => {},
            else => {
                try stderr.print("zs: -{c}: invalid option\n", .{flag});
                return 2;
            },
        };
    }

    const interactive = command == null and (force_interactive or std.io.getStdIn().isTty());
    if (interactive) executor.ignoreInteractiveSignals();

    var shell = executor.Shell{};

    if (login) {
        if (rc.loadProfiles(allocator, &shell)) |code| return code;
    }

    if (command) |text| {
        if (index + 1 < argv.len) try vars.setParams(argv[index + 1 ..]);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const exit_code = shell.run(arena.allocator(), text, null) catch |err| {
            try stderr.print("zs: {s}\n", .{parser.message(err) orelse @errorName(err)});
            return 2;
        };
        return exit_code orelse shell.last_status;
    }

    var editor = Editor.init(allocator, "");
    defer editor.deinit();
    editor.marks = interactive and supportsPromptMarks();
    var command_pending = false;

    if (interactive) {
        if (rc.load(allocator, &shell)) |code| return code;
        history.load();
    }

    while (true) {
        if (command_pending) {
            try stdout.print("\x1b]133;D;{d}\x07", .{shell.last_status});
            command_pending = false;
        }
        var prompt_arena = std.heap.ArenaAllocator.init(allocator);
        defer prompt_arena.deinit();
        editor.prompt = renderPrompt(&shell, prompt_arena.allocator(), interactive);
        const line = try editor.readLine() orelse break;
        command_pending = editor.marks;

        const input = std.mem.trim(u8, line, " \t\r");
        if (input.len == 0) continue;

        try editor.addHistory(input);

        if (arith.looksLikeExpression(input)) {
            if (arith.calculate(input)) |value| {
                try stdout.print("{d}\n", .{value});
                shell.last_status = 0;
            } else |err| {
                try stderr.print("zs: {s}\n", .{if (err == error.DivideByZero) "division by zero" else "syntax error in expression"});
                shell.last_status = 1;
            }
            continue;
        }

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
