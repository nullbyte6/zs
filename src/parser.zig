const std = @import("std");
const posix = std.posix;
const glob = @import("glob.zig");
const vars = @import("vars.zig");

pub const RedirectKind = enum { read, write, append, dup, heredoc };

pub const Redirect = struct {
    fd: u8,
    kind: RedirectKind,
    target: []const u8 = "",
    strip_tabs: bool = false,
};

pub const LineSource = struct {
    context: *anyopaque,
    next: *const fn (context: *anyopaque, arena: std.mem.Allocator) ?[]const u8,
};

pub const Command = struct {
    argv: []const []const u8,
    assignments: []const vars.Assignment = &.{},
    redirects: []const Redirect = &.{},
};

pub const Join = enum { always, and_if, or_if };

pub const Pipeline = struct {
    commands: []const Command,
    join: Join = .always,
};

pub const Error = error{
    UnterminatedQuote,
    UnsupportedOperator,
    MissingCommand,
    MissingTarget,
    BadSubstitution,
    OutOfMemory,
};

pub fn message(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.UnterminatedQuote => "syntax error: unterminated quote",
        error.UnsupportedOperator => "syntax error: unsupported operator",
        error.MissingTarget => "syntax error: missing redirection target",
        error.MissingCommand => "syntax error: missing command",
        error.BadSubstitution => "syntax error: bad substitution",
        error.OutOfMemory => "out of memory",
        else => null,
    };
}

const Expansion = struct {
    value: []const u8,
    end: usize,
};

pub const Parser = struct {
    arena: std.mem.Allocator,
    line: []const u8,
    pos: usize = 0,
    last_status: u8 = 0,
    word: std.ArrayList(u8),
    pattern: std.ArrayList(u8),
    has_glob: bool = false,
    in_word: bool = false,
    plain: bool = true,
    assign_name: ?[]const u8 = null,
    assignments: std.ArrayList(vars.Assignment),
    redirects: std.ArrayList(Redirect),
    pending_redirect: ?Redirect = null,
    word_quoted: bool = false,
    lines: ?LineSource = null,
    words: std.ArrayList([]const u8),
    commands: std.ArrayList(Command),
    pending_join: Join = .always,
    expect_more: bool = false,

    pub fn init(arena: std.mem.Allocator, line: []const u8) Parser {
        return .{
            .arena = arena,
            .line = line,
            .word = .init(arena),
            .pattern = .init(arena),
            .assignments = .init(arena),
            .redirects = .init(arena),
            .words = .init(arena),
            .commands = .init(arena),
        };
    }

    pub fn next(self: *Parser, last_status: u8) Error!?Pipeline {
        self.last_status = last_status;
        const line = self.line;
        while (self.pos < line.len) {
            const c = line[self.pos];
            switch (c) {
                ' ', '\t' => {
                    try self.flushWord();
                    self.pos += 1;
                },
                '\'' => {
                    self.plain = false;
                    self.word_quoted = true;
                    const end = std.mem.indexOfScalarPos(u8, line, self.pos + 1, '\'') orelse return error.UnterminatedQuote;
                    try self.appendLiteralSlice(line[self.pos + 1 .. end]);
                    self.in_word = true;
                    self.pos = end + 1;
                },
                '"' => {
                    self.plain = false;
                    self.word_quoted = true;
                    try self.doubleQuoted();
                },
                '\\' => {
                    self.plain = false;
                    self.word_quoted = true;
                    if (self.pos + 1 < line.len) {
                        try self.appendLiteral(line[self.pos + 1]);
                        self.pos += 2;
                    } else {
                        try self.appendLiteral('\\');
                        self.pos += 1;
                    }
                    self.in_word = true;
                },
                '$' => {
                    self.plain = false;
                    try self.expandVariable(false);
                },
                '|' => {
                    if (self.peek('|')) {
                        self.pos += 2;
                        return try self.endPipeline(.or_if);
                    }
                    try self.endCommand();
                    self.pos += 1;
                },
                ';' => {
                    self.pos += 1;
                    return try self.endPipeline(.always);
                },
                '&' => {
                    if (!self.peek('&')) return error.UnsupportedOperator;
                    self.pos += 2;
                    return try self.endPipeline(.and_if);
                },
                '<', '>' => try self.redirect(),
                '~' => {
                    self.plain = false;
                    if (!self.in_word and tildeEnds(line, self.pos + 1)) {
                        if (vars.get("HOME")) |home| {
                            try self.appendLiteralSlice(home);
                            self.in_word = true;
                            self.pos += 1;
                            continue;
                        }
                    }
                    try self.appendLiteral('~');
                    self.in_word = true;
                    self.pos += 1;
                },
                '*', '?', '[' => {
                    if (self.assign_name != null or self.pending_redirect != null) {
                        try self.appendLiteral(c);
                    } else {
                        try self.word.append(c);
                        try self.pattern.append(c);
                        self.has_glob = true;
                    }
                    self.plain = false;
                    self.in_word = true;
                    self.pos += 1;
                },
                '=' => {
                    if (self.in_word and self.plain and self.words.items.len == 0 and self.assign_name == null and self.pending_redirect == null and isName(self.word.items)) {
                        self.assign_name = try self.arena.dupe(u8, self.word.items);
                        self.word.clearRetainingCapacity();
                        self.pattern.clearRetainingCapacity();
                    } else {
                        try self.appendLiteral('=');
                        self.in_word = true;
                    }
                    self.pos += 1;
                },
                else => {
                    try self.appendLiteral(c);
                    self.in_word = true;
                    self.pos += 1;
                },
            }
        }

        try self.flushWord();
        if (self.words.items.len > 0 or self.assignments.items.len > 0 or self.redirects.items.len > 0 or self.pending_redirect != null) return try self.endPipeline(.always);
        if (self.commands.items.len > 0 or self.expect_more) return error.MissingCommand;
        return null;
    }

    fn flushWord(self: *Parser) Error!void {
        if (!self.in_word) return;
        self.plain = true;
        const quoted_word = self.word_quoted;
        self.word_quoted = false;
        if (self.pending_redirect) |pending| {
            var done = pending;
            const text = try self.word.toOwnedSlice();
            self.pattern.clearRetainingCapacity();
            done.target = if (done.kind == .heredoc) try self.readHeredoc(text, done.strip_tabs, quoted_word) else text;
            try self.redirects.append(done);
            self.pending_redirect = null;
            self.has_glob = false;
            self.in_word = false;
            return;
        }
        if (self.assign_name) |name| {
            try self.assignments.append(.{ .name = name, .value = try self.word.toOwnedSlice() });
            self.pattern.clearRetainingCapacity();
            self.assign_name = null;
            self.in_word = false;
            return;
        }
        const literal = try self.word.toOwnedSlice();
        const pattern = try self.pattern.toOwnedSlice();
        self.in_word = false;
        if (self.has_glob) {
            self.has_glob = false;
            const matches = try glob.expand(self.arena, pattern);
            if (matches.len > 0) {
                try self.words.appendSlice(matches);
                return;
            }
        }
        try self.words.append(literal);
    }

    fn appendLiteral(self: *Parser, c: u8) Error!void {
        try self.word.append(c);
        if (std.mem.indexOfScalar(u8, "*?[\\", c) != null) try self.pattern.append('\\');
        try self.pattern.append(c);
    }

    fn appendLiteralSlice(self: *Parser, bytes: []const u8) Error!void {
        for (bytes) |c| try self.appendLiteral(c);
    }

    fn endCommand(self: *Parser) Error!void {
        try self.flushWord();
        if (self.pending_redirect != null) return error.MissingTarget;
        if (self.words.items.len == 0 and self.assignments.items.len == 0 and self.redirects.items.len == 0) return error.MissingCommand;
        try self.commands.append(.{
            .argv = try self.words.toOwnedSlice(),
            .assignments = try self.assignments.toOwnedSlice(),
            .redirects = try self.redirects.toOwnedSlice(),
        });
    }

    fn endPipeline(self: *Parser, following: Join) Error!Pipeline {
        try self.endCommand();
        const pipeline = Pipeline{ .commands = try self.commands.toOwnedSlice(), .join = self.pending_join };
        self.pending_join = following;
        self.expect_more = following != .always;
        return pipeline;
    }

    fn redirect(self: *Parser) Error!void {
        const line = self.line;
        const op = line[self.pos];
        var fd: u8 = if (op == '<') 0 else 1;
        if (self.in_word and self.plain and self.assign_name == null and self.pending_redirect == null and isDigits(self.word.items)) {
            fd = std.fmt.parseInt(u8, self.word.items, 10) catch return error.UnsupportedOperator;
            self.word.clearRetainingCapacity();
            self.pattern.clearRetainingCapacity();
            self.in_word = false;
        } else {
            try self.flushWord();
        }
        if (self.pending_redirect != null) return error.MissingTarget;

        var kind: RedirectKind = if (op == '<') .read else .write;
        var strip = false;
        self.pos += 1;
        if (op == '>' and self.pos < line.len) {
            if (line[self.pos] == '>') {
                kind = .append;
                self.pos += 1;
            } else if (line[self.pos] == '&') {
                kind = .dup;
                self.pos += 1;
            }
        } else if (op == '<' and self.pos < line.len and line[self.pos] == '>') {
            return error.UnsupportedOperator;
        } else if (op == '<' and self.pos < line.len and line[self.pos] == '<') {
            self.pos += 1;
            if (self.pos < line.len and line[self.pos] == '<') return error.UnsupportedOperator;
            kind = .heredoc;
            if (self.pos < line.len and line[self.pos] == '-') {
                strip = true;
                self.pos += 1;
            }
        }
        self.pending_redirect = .{ .fd = fd, .kind = kind, .strip_tabs = strip };
    }

    fn peek(self: *Parser, expected: u8) bool {
        return self.pos + 1 < self.line.len and self.line[self.pos + 1] == expected;
    }

    fn doubleQuoted(self: *Parser) Error!void {
        const line = self.line;
        self.in_word = true;
        self.pos += 1;
        while (self.pos < line.len) {
            const c = line[self.pos];
            if (c == '"') {
                self.pos += 1;
                return;
            }
            if (c == '$') {
                try self.expandVariable(true);
                continue;
            }
            if (c == '\\' and self.pos + 1 < line.len and std.mem.indexOfScalar(u8, "\"\\$`", line[self.pos + 1]) != null) {
                try self.appendLiteral(line[self.pos + 1]);
                self.pos += 2;
                continue;
            }
            try self.appendLiteral(c);
            self.pos += 1;
        }
        return error.UnterminatedQuote;
    }

    fn expandVariable(self: *Parser, quoted: bool) Error!void {
        const expansion = try self.dollar(self.line, self.pos) orelse {
            try self.appendLiteral('$');
            self.in_word = true;
            self.pos += 1;
            return;
        };
        self.pos = expansion.end;
        if (quoted or self.assign_name != null or self.pending_redirect != null) {
            try self.appendLiteralSlice(expansion.value);
            return;
        }
        for (expansion.value) |b| {
            if (b == ' ' or b == '\t' or b == '\n') {
                try self.flushWord();
            } else {
                try self.appendLiteral(b);
                self.in_word = true;
            }
        }
    }

    fn dollar(self: *Parser, text: []const u8, start: usize) Error!?Expansion {
        const i = start + 1;
        if (i < text.len and text[i] == '?') {
            return .{ .value = try std.fmt.allocPrint(self.arena, "{d}", .{self.last_status}), .end = i + 1 };
        }
        if (i < text.len and text[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '}') orelse return error.BadSubstitution;
            const name = text[i + 1 .. end];
            if (!isName(name)) return error.BadSubstitution;
            return .{ .value = vars.get(name) orelse "", .end = end + 1 };
        }
        var end = i;
        while (end < text.len and isNameChar(text[end], end == i)) end += 1;
        if (end == i) return null;
        return .{ .value = vars.get(text[i..end]) orelse "", .end = end };
    }

    fn readHeredoc(self: *Parser, delimiter: []const u8, strip_tabs: bool, quoted: bool) Error![]const u8 {
        const source = self.lines orelse return error.UnsupportedOperator;
        var body = std.ArrayList(u8).init(self.arena);
        while (source.next(source.context, self.arena)) |raw| {
            const line = if (strip_tabs) std.mem.trimLeft(u8, raw, "\t") else raw;
            if (std.mem.eql(u8, line, delimiter)) break;
            try body.appendSlice(line);
            try body.append('\n');
        }
        if (quoted) return body.items;
        return self.expandBody(body.items);
    }

    fn expandBody(self: *Parser, text: []const u8) Error![]const u8 {
        var out = std.ArrayList(u8).init(self.arena);
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '\\' and i + 1 < text.len and std.mem.indexOfScalar(u8, "$`\\", text[i + 1]) != null) {
                try out.append(text[i + 1]);
                i += 2;
            } else if (c == '$') {
                if (try self.dollar(text, i)) |expansion| {
                    try out.appendSlice(expansion.value);
                    i = expansion.end;
                } else {
                    try out.append('$');
                    i += 1;
                }
            } else {
                try out.append(c);
                i += 1;
            }
        }
        return out.items;
    }
};

fn isNameChar(c: u8, first: bool) bool {
    return c == '_' or std.ascii.isAlphabetic(c) or (!first and std.ascii.isDigit(c));
}

fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

pub fn isName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        if (!isNameChar(c, i == 0)) return false;
    }
    return true;
}

fn tildeEnds(line: []const u8, index: usize) bool {
    if (index >= line.len) return true;
    return switch (line[index]) {
        ' ', '\t', '/', '|', ';' => true,
        else => false,
    };
}
