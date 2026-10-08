const std = @import("std");
const posix = std.posix;
const glob = @import("glob.zig");
const vars = @import("vars.zig");
const arith = @import("arith.zig");

pub const RedirectKind = enum { read, write, append, dup, heredoc };

pub const Redirect = struct {
    fd: u8,
    kind: RedirectKind,
    target: []const u8 = "",
    strip_tabs: bool = false,
    both: bool = false,
};

pub const Mode = enum { words, text, pattern };

pub const Substituter = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, arena: std.mem.Allocator, command: []const u8) Error![]const u8,
    status: *u8,
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
    SubstitutionFailed,
    BadSubstitution,
    BadArithmetic,
    DivideByZero,
    ParameterNull,
    UnboundVariable,
    OutOfMemory,
};

var unbound_name: [128]u8 = undefined;
var unbound_name_len: usize = 0;
var unbound_message: [160]u8 = undefined;

fn unbound(name: []const u8) error{UnboundVariable} {
    unbound_name_len = @min(name.len, unbound_name.len);
    @memcpy(unbound_name[0..unbound_name_len], name[0..unbound_name_len]);
    return error.UnboundVariable;
}

pub fn message(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.UnterminatedQuote => "syntax error: unterminated quote",
        error.UnsupportedOperator => "syntax error: unsupported operator",
        error.MissingTarget => "syntax error: missing redirection target",
        error.SubstitutionFailed => "command substitution failed",
        error.BadArithmetic => "syntax error in arithmetic expression",
        error.DivideByZero => "division by zero in arithmetic expression",
        error.ParameterNull => "parameter null or not set",
        error.UnboundVariable => std.fmt.bufPrint(&unbound_message, "{s}: unbound variable", .{unbound_name[0..unbound_name_len]}) catch "unbound variable",
        error.MissingCommand => "syntax error: missing command",
        error.BadSubstitution => "syntax error: bad substitution",
        error.Syntax => "syntax error: unexpected token or keyword",
        error.UnexpectedEof => "syntax error: unexpected end of input",
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
    mode: Mode = .words,
    at_empty: bool = false,
    last_pattern: []const u8 = "",
    lines: ?LineSource = null,
    substitute: ?Substituter = null,
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
                '#' => {
                    if (self.in_word) {
                        try self.appendLiteral('#');
                        self.pos += 1;
                    } else {
                        while (self.pos < line.len and line[self.pos] != '\n') self.pos += 1;
                    }
                },
                '$' => {
                    self.plain = false;
                    try self.expandVariable(false);
                },
                '`' => {
                    self.plain = false;
                    try self.expandBacktick(false);
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
                    if (self.peek('>')) {
                        try self.redirect();
                    } else {
                        if (!self.peek('&')) return error.UnsupportedOperator;
                        self.pos += 2;
                        return try self.endPipeline(.and_if);
                    }
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
                    if (self.assign_name != null or self.pending_redirect != null or self.mode == .text) {
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
            if (done.both) try self.redirects.append(.{ .fd = 2, .kind = .dup, .target = "1" });
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
        if (self.mode == .pattern) self.last_pattern = pattern;
        if (self.has_glob) {
            self.has_glob = false;
            if (self.mode == .words) {
                const matches = try glob.expand(self.arena, pattern);
                if (matches.len > 0) {
                    try self.words.appendSlice(matches);
                    return;
                }
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
        if (op == '&') {
            try self.flushWord();
            if (self.pending_redirect != null) return error.MissingTarget;
            self.pos += 2;
            var both_kind: RedirectKind = .write;
            if (self.pos < line.len and line[self.pos] == '>') {
                both_kind = .append;
                self.pos += 1;
            }
            self.pending_redirect = .{ .fd = 1, .kind = both_kind, .both = true };
            return;
        }
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
        const was_in_word = self.in_word;
        self.at_empty = false;
        self.in_word = true;
        self.pos += 1;
        while (self.pos < line.len) {
            const c = line[self.pos];
            if (c == '"') {
                self.pos += 1;
                if (self.at_empty and !was_in_word and self.word.items.len == 0) {
                    self.in_word = false;
                    self.plain = true;
                    self.word_quoted = false;
                }
                return;
            }
            if (c == '$') {
                try self.expandVariable(true);
                continue;
            }
            if (c == '`') {
                try self.expandBacktick(true);
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

    fn quotedAtEnd(self: *Parser) ?usize {
        const line = self.line;
        if (std.mem.startsWith(u8, line[self.pos..], "$@")) return self.pos + 2;
        if (std.mem.startsWith(u8, line[self.pos..], "${@}")) return self.pos + 4;
        return null;
    }

    fn expandAt(self: *Parser) Error!void {
        const items = vars.params();
        if (items.len == 0) self.at_empty = true;
        for (items, 0..) |item, index| {
            if (index > 0) try self.flushWord();
            try self.appendLiteralSlice(item);
            self.in_word = true;
        }
    }

    fn expandVariable(self: *Parser, quoted: bool) Error!void {
        if (quoted and self.mode == .words and self.assign_name == null and self.pending_redirect == null) {
            if (self.quotedAtEnd()) |end| {
                try self.expandAt();
                self.pos = end;
                return;
            }
        }
        const expansion = try self.dollar(self.line, self.pos) orelse {
            try self.appendLiteral('$');
            self.in_word = true;
            self.pos += 1;
            return;
        };
        self.pos = expansion.end;
        try self.appendExpansion(expansion.value, quoted);
    }

    fn expandBacktick(self: *Parser, quoted: bool) Error!void {
        const expansion = try self.backtick(self.line, self.pos);
        self.pos = expansion.end;
        try self.appendExpansion(expansion.value, quoted);
    }

    fn appendExpansion(self: *Parser, value: []const u8, quoted: bool) Error!void {
        if (quoted or self.assign_name != null or self.pending_redirect != null or self.mode != .words) {
            try self.appendLiteralSlice(value);
            self.in_word = true;
            return;
        }
        for (value) |b| {
            if (b == ' ' or b == '\t' or b == '\n') {
                try self.flushWord();
            } else {
                try self.appendLiteral(b);
                self.in_word = true;
            }
        }
    }

    fn substituteCommand(self: *Parser, command: []const u8) Error![]const u8 {
        const substituter = self.substitute orelse return error.UnsupportedOperator;
        const output = try substituter.run(substituter.context, self.arena, command);
        self.last_status = substituter.status.*;
        return output;
    }

    fn backtick(self: *Parser, text: []const u8, start: usize) Error!Expansion {
        var i = start + 1;
        while (i < text.len and text[i] != '`') {
            i += if (text[i] == '\\' and i + 1 < text.len) 2 else 1;
        }
        if (i >= text.len) return error.UnterminatedQuote;
        return .{ .value = try self.substituteCommand(text[start + 1 .. i]), .end = i + 1 };
    }

    fn dollar(self: *Parser, text: []const u8, start: usize) Error!?Expansion {
        const i = start + 1;
        if (i < text.len and text[i] == '(') {
            const close = findParenEnd(text, i) orelse return error.UnterminatedQuote;
            if (i + 1 < text.len and text[i + 1] == '(') {
                if (close < i + 3 or text[close - 1] != ')') return error.UnsupportedOperator;
                const expression = try self.expandBody(text[i + 2 .. close - 1]);
                const result = arith.eval(expression) catch |err| return switch (err) {
                    error.DivideByZero => error.DivideByZero,
                    error.Syntax => error.BadArithmetic,
                };
                return .{ .value = try std.fmt.allocPrint(self.arena, "{d}", .{result}), .end = close + 1 };
            }
            return .{ .value = try self.substituteCommand(text[i + 1 .. close]), .end = close + 1 };
        }
        if (i < text.len and (std.mem.indexOfScalar(u8, "?#$@*", text[i]) != null or std.ascii.isDigit(text[i]))) {
            if (vars.nounset and std.ascii.isDigit(text[i]) and text[i] != '0' and text[i] - '0' > vars.params().len) return unbound(text[i .. i + 1]);
            return .{ .value = try self.special(text[i .. i + 1]), .end = i + 1 };
        }
        if (i < text.len and text[i] == '{') {
            const end = findBraceEnd(text, i) orelse return error.BadSubstitution;
            return .{ .value = try self.braced(text[i + 1 .. end]), .end = end + 1 };
        }
        var end = i;
        while (end < text.len and isNameChar(text[end], end == i)) end += 1;
        if (end == i) return null;
        const value = vars.get(text[i..end]) orelse {
            if (vars.nounset) return unbound(text[i..end]);
            return .{ .value = "", .end = end };
        };
        return .{ .value = value, .end = end };
    }

    fn lookup(self: *Parser, name: []const u8) Error!?[]const u8 {
        if (isDigits(name)) {
            const index = std.fmt.parseInt(usize, name, 10) catch return null;
            if (index > vars.params().len) return null;
            return try self.special(name);
        }
        if (isSpecialName(name)) return try self.special(name);
        return vars.get(name);
    }

    fn braced(self: *Parser, content: []const u8) Error![]const u8 {
        if (content.len == 0) return error.BadSubstitution;
        if (content[0] == '#' and content.len > 1) {
            const target = content[1..];
            if (std.mem.eql(u8, target, "@") or std.mem.eql(u8, target, "*")) {
                return std.fmt.allocPrint(self.arena, "{d}", .{vars.params().len});
            }
            if (!isName(target) and !isDigits(target)) return error.BadSubstitution;
            const value = (try self.lookup(target)) orelse {
                if (vars.nounset) return unbound(target);
                return "0";
            };
            const length = std.unicode.utf8CountCodepoints(value) catch value.len;
            return std.fmt.allocPrint(self.arena, "{d}", .{length});
        }
        var name_end: usize = 0;
        if (std.ascii.isDigit(content[0])) {
            while (name_end < content.len and std.ascii.isDigit(content[name_end])) name_end += 1;
        } else if (std.mem.indexOfScalar(u8, "?#$@*", content[0]) != null) {
            name_end = 1;
        } else {
            while (name_end < content.len and isNameChar(content[name_end], name_end == 0)) name_end += 1;
        }
        if (name_end == 0) return error.BadSubstitution;
        const name = content[0..name_end];
        const rest = content[name_end..];
        const current = try self.lookup(name);
        if (rest.len == 0) {
            if (current) |value| return value;
            if (vars.nounset) return unbound(name);
            return "";
        }

        const colon = rest[0] == ':';
        const op_index: usize = if (colon) 1 else 0;
        if (op_index >= rest.len or std.mem.indexOfScalar(u8, "-=+?", rest[op_index]) == null) return error.BadSubstitution;
        const operand = rest[op_index + 1 ..];
        const missing = current == null or (colon and current.?.len == 0);
        switch (rest[op_index]) {
            '-' => return if (missing) try self.expandOperand(operand) else current.?,
            '+' => return if (missing) "" else try self.expandOperand(operand),
            '=' => {
                if (!missing) return current.?;
                if (!isName(name)) return error.BadSubstitution;
                const value = try self.expandOperand(operand);
                vars.set(name, value) catch return error.OutOfMemory;
                return value;
            },
            else => {
                if (missing) return error.ParameterNull;
                return current.?;
            },
        }
    }

    fn expandOperand(self: *Parser, operand: []const u8) Error![]const u8 {
        var out = std.ArrayList(u8).init(self.arena);
        var i: usize = 0;
        while (i < operand.len) {
            if (operand[i] == '\'') {
                const close = std.mem.indexOfScalarPos(u8, operand, i + 1, '\'') orelse return error.UnterminatedQuote;
                try out.appendSlice(operand[i + 1 .. close]);
                i = close + 1;
            } else if (operand[i] == '"') {
                var close = i + 1;
                while (close < operand.len and operand[close] != '"') close += if (operand[close] == '\\') 2 else 1;
                if (close >= operand.len) return error.UnterminatedQuote;
                try out.appendSlice(try self.expandBody(operand[i + 1 .. close]));
                i = close + 1;
            } else {
                var end = i;
                while (end < operand.len and operand[end] != '\'' and operand[end] != '"') end += 1;
                try out.appendSlice(try self.expandBody(operand[i..end]));
                i = end;
            }
        }
        return out.items;
    }

    fn special(self: *Parser, name: []const u8) Error![]const u8 {
        if (name.len == 1) {
            switch (name[0]) {
                '?' => return std.fmt.allocPrint(self.arena, "{d}", .{self.last_status}),
                '#' => return std.fmt.allocPrint(self.arena, "{d}", .{vars.params().len}),
                '$' => return std.fmt.allocPrint(self.arena, "{d}", .{vars.shell_pid}),
                '@', '*' => {
                    const ifs = vars.get("IFS") orelse " \t\n";
                    const separator: []const u8 = if (name[0] == '*' and ifs.len > 0) ifs[0..1] else " ";
                    return std.mem.join(self.arena, separator, vars.params());
                },
                else => {},
            }
        }
        const index = std.fmt.parseInt(usize, name, 10) catch return "";
        if (index == 0) return "zs";
        if (index > vars.params().len) return "";
        return vars.params()[index - 1];
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

    pub fn expandBody(self: *Parser, text: []const u8) Error![]const u8 {
        var out = std.ArrayList(u8).init(self.arena);
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '\\' and i + 1 < text.len and std.mem.indexOfScalar(u8, "$`\\", text[i + 1]) != null) {
                try out.append(text[i + 1]);
                i += 2;
            } else if (c == '`') {
                const expansion = try self.backtick(text, i);
                try out.appendSlice(expansion.value);
                i = expansion.end;
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

pub fn findParenEnd(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            '\\' => i += 1,
            '\'' => i = std.mem.indexOfScalarPos(u8, text, i + 1, '\'') orelse return null,
            '"' => {
                i += 1;
                while (i < text.len and text[i] != '"') i += if (text[i] == '\\') 2 else 1;
            },
            else => {},
        }
    }
    return null;
}

pub fn findBraceEnd(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            '\\' => i += 1,
            '\'' => i = std.mem.indexOfScalarPos(u8, text, i + 1, '\'') orelse return null,
            '"' => {
                i += 1;
                while (i < text.len and text[i] != '"') i += if (text[i] == '\\') 2 else 1;
            },
            else => {},
        }
    }
    return null;
}

fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn isSpecialName(name: []const u8) bool {
    if (name.len == 1 and std.mem.indexOfScalar(u8, "?#$@*", name[0]) != null) return true;
    return isDigits(name);
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
