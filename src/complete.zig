const std = @import("std");
const commands = @import("commands.zig");
const functions = @import("functions.zig");
const spec = @import("spec.zig");
const vars = @import("vars.zig");

const keywords = [_][]const u8{ "if", "then", "elif", "else", "fi", "while", "until", "do", "done", "for", "case", "esac", "function", "select" };
const command_keywords = [_][]const u8{ "if", "then", "elif", "else", "while", "until", "do", "!", "{", "time" };

pub const Candidate = struct {
    text: []const u8,
    suffix: []const u8 = " ",
    rank: u8 = std.math.maxInt(u8),
};

pub const Hint = struct {
    label: []const u8,
    quoted: bool,
};

pub const Result = struct {
    start: usize,
    typed: []const u8,
    candidates: []const Candidate,
};

const Words = struct {
    items: [16][]const u8 = undefined,
    len: usize = 0,
    total: usize = 0,
    last: []const u8 = "",

    fn push(self: *Words, word: []const u8) void {
        if (self.len < self.items.len) {
            self.items[self.len] = word;
            self.len += 1;
        }
        self.total += 1;
        self.last = word;
    }

    fn reset(self: *Words) void {
        self.len = 0;
        self.total = 0;
        self.last = "";
    }

    fn sub(self: *const Words) []const u8 {
        if (self.len < 2 or self.items[1].len == 0 or self.items[1][0] == '-') return "";
        return self.items[1];
    }
};

const Lists = struct {
    starts: std.ArrayList(Candidate),
    contains: std.ArrayList(Candidate),
};

const string_hints = [_][]const u8{ "msg", "message", "string", "text", "comment", "subject", "title", "description", "pattern", "regex", "expr", "expression", "str" };

const Context = struct {
    start: usize,
    word: []const u8,
    expect_command: bool,
    words: Words,
};

pub fn complete(arena: std.mem.Allocator, line: []const u8, cursor: usize) !?Result {
    const context = analyze(line[0..cursor]) orelse return null;
    if (std.mem.indexOfAny(u8, context.word, "'\"$`") != null) return null;
    const plain = try unescape(arena, context.word);

    var lists = Lists{ .starts = .init(arena), .contains = .init(arena) };
    const command_like = context.expect_command and std.mem.indexOfScalar(u8, plain, '/') == null and !std.mem.startsWith(u8, plain, "~");
    if (command_like) {
        if (plain.len == 0) return null;
        try collectCommands(arena, plain, &lists);
    } else if (!try collectArguments(arena, context, plain, &lists)) {
        try collectFiles(arena, plain, &lists.starts);
    }

    const starts = uniqueCandidates(lists.starts.items);
    const contains = uniqueCandidates(lists.contains.items);
    var all = std.ArrayList(Candidate).init(arena);
    try all.appendSlice(starts);
    try all.appendSlice(contains);
    return .{
        .start = context.start,
        .typed = try escape(arena, plain, true),
        .candidates = all.items,
    };
}

pub fn hint(line: []const u8, cursor: usize) ?Hint {
    const context = analyze(line[0..cursor]) orelse return null;
    const words = context.words;
    if (words.len == 0 or context.expect_command) return null;
    const option = if (context.word.len == 0) words.last else if (std.mem.endsWith(u8, context.word, "=")) context.word else return null;
    if (option.len < 2 or option[0] != '-') return null;
    const found = spec.find(baseName(words.items[0]), words.sub(), option) orelse return null;
    const label = std.mem.trim(u8, found.hint, "<>");
    if (label.len == 0) return null;
    var quoted = false;
    for (string_hints) |name| {
        if (std.ascii.eqlIgnoreCase(name, label)) quoted = true;
    }
    return .{ .label = label, .quoted = quoted };
}

fn uniqueCandidates(items: []Candidate) []Candidate {
    std.mem.sort(Candidate, items, {}, lessThan);
    var unique: usize = 0;
    for (items) |candidate| {
        if (unique > 0 and std.mem.eql(u8, items[unique - 1].text, candidate.text)) continue;
        items[unique] = candidate;
        unique += 1;
    }
    return items[0..unique];
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn analyze(prefix: []const u8) ?Context {
    var expect_command = true;
    var after_redirect = false;
    var in_word = false;
    var word_start: usize = 0;
    var quote: u8 = 0;
    var words = Words{};
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
                    finishWord(prefix[word_start..i], c, &expect_command, &after_redirect, &words);
                    in_word = false;
                }
                switch (c) {
                    '|', ';', '(', '\n' => {
                        expect_command = true;
                        words.reset();
                    },
                    '&' => {
                        if (i + 1 < prefix.len and prefix[i + 1] == '>') {
                            after_redirect = true;
                        } else {
                            expect_command = true;
                            words.reset();
                        }
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
        .words = words,
    };
}

fn finishWord(word: []const u8, operator: u8, expect_command: *bool, after_redirect: *bool, words: *Words) void {
    if ((operator == '<' or operator == '>') and !after_redirect.* and isDigits(word)) return;
    if (after_redirect.*) {
        after_redirect.* = false;
        return;
    }
    if (!expect_command.*) {
        words.push(word);
        return;
    }
    if (isOneOf(&command_keywords, word) or isAssignment(word)) return;
    expect_command.* = false;
    words.push(word);
}

fn collectCommands(arena: std.mem.Allocator, prefix: []const u8, lists: *Lists) !void {
    for (keywords) |keyword| try offer(arena, lists, prefix, keyword, " ");
    for (commands.builtins) |builtin| try offer(arena, lists, prefix, builtin, " ");
    for (try functions.names(arena)) |name| try offer(arena, lists, prefix, name, " ");
    for (spec.commandNames()) |name| try offer(arena, lists, prefix, name, " ");
}

fn collectArguments(arena: std.mem.Allocator, context: Context, plain: []const u8, lists: *Lists) !bool {
    const words = context.words;
    if (words.len == 0 or context.expect_command) return false;
    const command = baseName(words.items[0]);
    if (plain.len > 0 and plain[0] == '-') {
        for (spec.options(command, words.sub())) |option| {
            const suffix: []const u8 = if (std.mem.endsWith(u8, option.text, "=")) "" else " ";
            try offer(arena, lists, plain, option.text, suffix);
        }
    } else if (words.total == 1 and (plain.len == 0 or std.mem.indexOfAny(u8, plain[0..1], "/.~") == null)) {
        const starts_before = lists.starts.items.len;
        const contains_before = lists.contains.items.len;
        for (spec.subcommands(command)) |name| try offer(arena, lists, plain, name, " ");
        for (lists.starts.items[starts_before..]) |*candidate| candidate.rank = spec.popularity(command, candidate.text);
        for (lists.contains.items[contains_before..]) |*candidate| candidate.rank = spec.popularity(command, candidate.text);
    }
    return lists.starts.items.len + lists.contains.items.len > 0;
}

fn offer(arena: std.mem.Allocator, lists: *Lists, typed: []const u8, name: []const u8, suffix: []const u8) !void {
    const bucket = if (std.mem.startsWith(u8, name, typed))
        &lists.starts
    else if (typed.len >= 2 and std.mem.indexOf(u8, name, typed) != null)
        &lists.contains
    else
        return;
    try bucket.append(.{ .text = try escape(arena, name, false), .suffix = suffix });
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
        const trailing: []const u8 = if (is_dir) "/" else "";
        try list.append(.{
            .text = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ escaped_dir, name, trailing }),
            .suffix = if (is_dir) "" else " ",
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
    if (a.rank != b.rank) return a.rank < b.rank;
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
