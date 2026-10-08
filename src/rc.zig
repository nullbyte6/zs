const std = @import("std");
const executor = @import("executor.zig");
const parser = @import("parser.zig");
const vars = @import("vars.zig");
const diag = @import("diag.zig");

const Source = struct {
    text: []const u8,
    pos: usize = 0,
    line_no: usize = 0,

    fn take(self: *Source) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const end = std.mem.indexOfScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
        const line = self.text[self.pos..end];
        self.pos = @min(end + 1, self.text.len);
        self.line_no += 1;
        return line;
    }
};

fn nextLine(context: *anyopaque, arena: std.mem.Allocator) ?[]const u8 {
    const source: *Source = @ptrCast(@alignCast(context));
    const line = source.take() orelse return null;
    return arena.dupe(u8, line) catch null;
}

pub fn load(allocator: std.mem.Allocator, shell: *executor.Shell) ?u8 {
    const home = vars.get("HOME") orelse return null;
    const path = std.fmt.allocPrint(allocator, "{s}/.zsrc", .{home}) catch return null;
    defer allocator.free(path);

    const result = runFile(allocator, shell, path, "~/.zsrc") catch |err| {
        if (err != error.FileNotFound) diag.warning("~/.zsrc: cannot read: {s}", .{@errorName(err)});
        return null;
    };
    shell.last_status = 0;
    return result;
}

pub fn loadProfiles(allocator: std.mem.Allocator, shell: *executor.Shell) ?u8 {
    if (profile(allocator, shell, "/etc/profile", "/etc/profile")) |code| return code;
    const home = vars.get("HOME") orelse return null;
    const path = std.fmt.allocPrint(allocator, "{s}/.profile", .{home}) catch return null;
    defer allocator.free(path);
    return profile(allocator, shell, path, "~/.profile");
}

fn profile(allocator: std.mem.Allocator, shell: *executor.Shell, path: []const u8, label: []const u8) ?u8 {
    const result = runFile(allocator, shell, path, label) catch |err| {
        if (err != error.FileNotFound) diag.warning("{s}: cannot read: {s}", .{ label, @errorName(err) });
        return null;
    };
    shell.last_status = 0;
    return result;
}

pub fn runFile(allocator: std.mem.Allocator, shell: *executor.Shell, path: []const u8, label: []const u8) !?u8 {
    const text = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(text);

    var source = Source{ .text = text };
    while (source.take()) |line| {
        const first_line = source.line_no;
        const input = std.mem.trim(u8, line, " \t\r");
        if (input.len == 0) continue;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const owned = arena.allocator().dupe(u8, input) catch continue;
        const exit_code = shell.run(arena.allocator(), owned, .{ .context = &source, .next = nextLine }) catch |err| {
            diag.failure("{s}:{d}: {s}", .{ label, first_line, parser.message(err) orelse @errorName(err) });
            shell.last_status = 2;
            continue;
        };
        if (exit_code) |code| return code;
        if (shell.last_status == 127) diag.warning("{s}:{d}: command not found", .{ label, first_line });
    }
    return null;
}
