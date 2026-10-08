const std = @import("std");
const commands = @import("commands.zig");
const functions = @import("functions.zig");
const vars = @import("vars.zig");

const keywords = [_][]const u8{ "if", "then", "elif", "else", "fi", "while", "until", "do", "done", "for", "case", "esac", "function", "select" };
const command_keywords = [_][]const u8{ "if", "then", "elif", "else", "while", "until", "do", "!", "{", "time" };

pub const Candidate = struct {
    text: []const u8,
    label: []const u8,
    is_dir: bool = false,
};

pub const Result = struct {
    start: usize,
    typed: []const u8,
    candidates: []const Candidate,
};

const Context = struct {
    start: usize,
    word: []const u8,
    expect_command: bool,
};

pub fn complete(arena: std.mem.Allocator, line: []const u8, cursor: usize) !?Result {
    const context = analyze(line[0..cursor]) orelse return null;
    if (std.mem.indexOfAny(u8, context.word, "'\"$`") != null) return null;
    const plain = try unescape(arena, context.word);

    var list = std.ArrayList(Candidate).init(arena);
    const command_like = context.expect_command and std.mem.indexOfScalar(u8, plain, '/') == null and !std.mem.startsWith(u8, plain, "~");
    if (command_like) {
        if (plain.len == 0) return null;
        try collectCommands(arena, plain, &list);
    } else {
        try collectFiles(arena, plain, &list);
    }

    std.mem.sort(Candidate, list.items, {}, lessThan);
    var unique: usize = 0;
    for (list.items) |candidate| {
        if (unique > 0 and std.mem.eql(u8, list.items[unique - 1].text, candidate.text)) continue;
        list.items[unique] = candidate;
        unique += 1;
    }
    return .{
        .start = context.start,
        .typed = try escape(arena, plain, true),
        .candidates = list.items[0..unique],
    };
}

fn analyze(prefix: []const u8) ?Context {
    var expect_command = true;
    var after_redirect = false;
    var in_word = false;
    var word_start: usize = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) {
        const c = prefix[i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else if (quote == '"' and c == '\\') {
                i += 1;
            }
            continue;
        }
        switch (c) {
            ' ', '\t', '\n', '|', '&', ';', '<', '>', '(', ')' => {
                if (in_word) {
                    finishWord(prefix[word_start..i], c, &expect_command, &after_redirect);
                    in_word = false;
                }
                switch (c) {
                    '|', ';', '(', '\n' => expect_command = true,
                    '&' => {
                        if (i + 1 < prefix.len and prefix[i + 1] == '>') after_redirect = true else expect_command = true;
                    },
                    '<', '>' => after_redirect = true,
                    ')' => expect_command = false,
                    else => {},
                }
            },
            else => {
                if (!in_word) {
                    in_word = true;
                    word_start = i;
                }
                if (c == '\'' or c == '"') {
                    quote = c;
                } else if (c == '\\') {
                    i += 1;
                }
            },
        }
    }
    if (quote != 0) return null;
    return .{
        .start = if (in_word) word_start else prefix.len,
        .word = if (in_word) prefix[word_start..] else "",
        .expect_command = expect_command and !after_redirect,
    };
}

fn finishWord(word: []const u8, operator: u8, expect_command: *bool, after_redirect: *bool) void {
    if ((operator == '<' or operator == '>') and !after_redirect.* and isDigits(word)) return;
    if (after_redirect.*) {
        after_redirect.* = false;
        return;
    }
    if (!expect_command.*) return;
    if (isOneOf(&command_keywords, word) or isAssignment(word)) return;
    expect_command.* = false;
}

fn collectCommands(arena: std.mem.Allocator, prefix: []const u8, list: *std.ArrayList(Candidate)) !void {
    for (keywords) |keyword| try addName(arena, prefix, keyword, list);
    for (commands.builtins) |builtin| try addName(arena, prefix, builtin, list);
    for (try functions.names(arena)) |name| try addName(arena, prefix, name, list);

    const path = vars.get("PATH") orelse return;
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir_path| {
        var dir = std.fs.cwd().openDir(if (dir_path.len == 0) "." else dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            try addName(arena, prefix, entry.name, list);
        }
    }
}

fn addName(arena: std.mem.Allocator, prefix: []const u8, name: []const u8, list: *std.ArrayList(Candidate)) !void {
    if (!std.mem.startsWith(u8, name, prefix)) return;
    const text = try escape(arena, name, false);
    try list.append(.{ .text = text, .label = text });
}

fn collectFiles(arena: std.mem.Allocator, plain: []const u8, list: *std.ArrayList(Candidate)) !void {
    const slash = std.mem.lastIndexOfScalar(u8, plain, '/');
    const dir_part = if (slash) |index| plain[0 .. index + 1] else "";
    const base = plain[dir_part.len..];

    var open_path: []const u8 = if (dir_part.len == 0) "." else dir_part;
    if (std.mem.startsWith(u8, dir_part, "~/")) {
        const home = vars.get("HOME") orelse return;
        open_path = try std.fmt.allocPrint(arena, "{s}{s}", .{ home, dir_part[1..] });
    }
    var dir = std.fs.cwd().openDir(open_path, .{ .iterate = true }) catch return;
    defer dir.close();

    const escaped_dir = try escape(arena, dir_part, true);
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, base)) continue;
        if (entry.name[0] == '.' and (base.len == 0 or base[0] != '.')) continue;
        var is_dir = entry.kind == .directory;
        if (entry.kind == .sym_link) {
            if (dir.statFile(entry.name)) |stat| is_dir = stat.kind == .directory else |_| {}
        }
        const name = try escape(arena, entry.name, false);
        const suffix: []const u8 = if (is_dir) "/" else "";
        try list.append(.{
            .text = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ escaped_dir, name, suffix }),
            .label = try std.fmt.allocPrint(arena, "{s}{s}", .{ try arena.dupe(u8, entry.name), suffix }),
            .is_dir = is_dir,
        });
    }
}

fn unescape(arena: std.mem.Allocator, word: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var i: usize = 0;
    while (i < word.len) : (i += 1) {
        if (word[i] == '\\' and i + 1 < word.len) i += 1;
        try out.append(word[i]);
    }
    return out.items;
}

fn escape(arena: std.mem.Allocator, text: []const u8, keep_tilde: bool) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    for (text, 0..) |c, index| {
        const special = std.mem.indexOfScalar(u8, " \t\n'\"\\$`&|;<>()*?[]{}#!^", c) != null;
        const tilde = c == '~' and index == 0 and !keep_tilde;
        if (special or tilde) try out.append('\\');
        try out.append(c);
    }
    return out.items;
}

fn lessThan(_: void, a: Candidate, b: Candidate) bool {
    return std.mem.lessThan(u8, a.text, b.text);
}

fn isOneOf(set: []const []const u8, word: []const u8) bool {
    for (set) |candidate| {
        if (std.mem.eql(u8, candidate, word)) return true;
    }
    return false;
}

fn isDigits(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn isAssignment(word: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (eq == 0 or std.ascii.isDigit(word[0])) return false;
    for (word[0..eq]) |c| {
        if (c != '_' and !std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}
