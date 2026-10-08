const std = @import("std");
const parser = @import("parser.zig");

pub const Join = parser.Join;

pub const Item = struct {
    node: Node,
    join: Join = .always,
};

pub const List = []const Item;

pub const Branch = struct {
    cond: List,
    body: List,
};

pub const IfClause = struct {
    branches: []const Branch,
    else_body: ?List,
};

pub const Loop = struct {
    until: bool,
    cond: List,
    body: List,
};

pub const ForClause = struct {
    name: []const u8,
    words: []const u8,
    body: List,
};

pub const Redirected = struct {
    node: *const Node,
    redirs: []const u8,
};

pub const Node = union(enum) {
    simple: []const u8,
    pipeline: []const Node,
    redirected: Redirected,
    arith: []const u8,
    if_clause: IfClause,
    loop: Loop,
    for_clause: ForClause,
};

pub const Error = error{ Incomplete, Syntax, OutOfMemory };

pub fn hasCompound(list: List) bool {
    for (list) |item| {
        switch (item.node) {
            .simple => {},
            else => return true,
        }
    }
    return false;
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!List {
    var p = Parser{ .arena = arena, .text = text };
    return p.parseList(&.{});
}

const reserved = [_][]const u8{ "if", "then", "elif", "else", "fi", "while", "until", "do", "done", "for", "in" };

const Parser = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,

    fn eof(self: *Parser) bool {
        return self.pos >= self.text.len;
    }

    fn skipBlanks(self: *Parser) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) self.pos += 1;
    }

    fn skipSeparators(self: *Parser) void {
        while (self.pos < self.text.len) {
            switch (self.text[self.pos]) {
                ' ', '\t', '\n', ';' => self.pos += 1,
                '#' => while (self.pos < self.text.len and self.text[self.pos] != '\n') {
                    self.pos += 1;
                },
                else => return,
            }
        }
    }

    fn peekWord(self: *Parser) []const u8 {
        var end = self.pos;
        while (end < self.text.len and std.mem.indexOfScalar(u8, " \t\n;&|<>()'\"`$\\#", self.text[end]) == null) end += 1;
        return self.text[self.pos..end];
    }

    fn parseList(self: *Parser, terminators: []const []const u8) Error!List {
        var items = std.ArrayList(Item).init(self.arena);
        var join: Join = .always;
        var need_command = false;
        while (true) {
            self.skipSeparators();
            if (self.eof()) {
                if (need_command or terminators.len > 0) return error.Incomplete;
                break;
            }
            const word = self.peekWord();
            if (isOneOf(terminators, word)) {
                if (need_command) return error.Syntax;
                break;
            }
            const node = try self.finishCommand(try self.parseCommand());
            try items.append(.{ .node = node, .join = join });
            join = .always;
            need_command = false;
            self.skipBlanks();
            if (std.mem.startsWith(u8, self.text[self.pos..], "&&")) {
                self.pos += 2;
                join = .and_if;
                need_command = true;
            } else if (std.mem.startsWith(u8, self.text[self.pos..], "||")) {
                self.pos += 2;
                join = .or_if;
                need_command = true;
            } else if (!self.eof() and self.text[self.pos] != ';' and self.text[self.pos] != '\n' and self.text[self.pos] != '#') {
                return error.Syntax;
            }
        }
        return items.items;
    }

    fn parseCommand(self: *Parser) Error!Node {
        if (std.mem.startsWith(u8, self.text[self.pos..], "((")) return self.parseArith();
        const word = self.peekWord();
        if (std.mem.eql(u8, word, "if")) return self.parseIf();
        if (std.mem.eql(u8, word, "while") or std.mem.eql(u8, word, "until")) return self.parseLoop();
        if (std.mem.eql(u8, word, "for")) return self.parseFor();
        if (isOneOf(&reserved, word)) return error.Syntax;
        return .{ .simple = try self.scanSpan() };
    }

    fn finishCommand(self: *Parser, first: Node) Error!Node {
        var current = first;
        if (current != .simple) current = try self.attachRedirects(current);
        self.skipBlanks();
        if (!self.atPipe()) return current;
        var stages = std.ArrayList(Node).init(self.arena);
        try stages.append(current);
        while (self.atPipe()) {
            self.pos += 1;
            while (self.pos < self.text.len and std.mem.indexOfScalar(u8, " \t\n", self.text[self.pos]) != null) self.pos += 1;
            if (self.eof()) return error.Incomplete;
            var stage = try self.parseCommand();
            if (stage != .simple) stage = try self.attachRedirects(stage);
            try stages.append(stage);
            self.skipBlanks();
        }
        return .{ .pipeline = stages.items };
    }

    fn atPipe(self: *Parser) bool {
        if (self.pos >= self.text.len or self.text[self.pos] != '|') return false;
        return !(self.pos + 1 < self.text.len and self.text[self.pos + 1] == '|');
    }

    fn attachRedirects(self: *Parser, node: Node) Error!Node {
        const redirs = try self.scanRedirects();
        if (redirs.len == 0) return node;
        const boxed = try self.arena.create(Node);
        boxed.* = node;
        return .{ .redirected = .{ .node = boxed, .redirs = redirs } };
    }

    fn scanRedirects(self: *Parser) Error![]const u8 {
        const text = self.text;
        self.skipBlanks();
        const start = self.pos;
        while (true) {
            self.skipBlanks();
            var i = self.pos;
            while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
            const is_amp = i == self.pos and i + 1 < text.len and text[i] == '&' and text[i + 1] == '>';
            if (!(i < text.len and (text[i] == '<' or text[i] == '>')) and !is_amp) break;
            if (std.mem.startsWith(u8, text[i..], "<<")) return error.Syntax;
            while (i < text.len and std.mem.indexOfScalar(u8, "<>&", text[i]) != null) i += 1;
            self.pos = i;
            self.skipBlanks();
            const word_start = self.pos;
            var j = word_start;
            while (j < text.len and std.mem.indexOfScalar(u8, " \t\n;&|<>", text[j]) == null) {
                switch (text[j]) {
                    '\'' => j = (std.mem.indexOfScalarPos(u8, text, j + 1, '\'') orelse return error.Incomplete) + 1,
                    '"' => j = try skipDouble(text, j),
                    '\\' => j = @min(j + 2, text.len),
                    '$' => {
                        if (j + 1 < text.len and text[j + 1] == '(') {
                            j = (parser.findParenEnd(text, j + 1) orelse return error.Incomplete) + 1;
                        } else {
                            j += 1;
                        }
                    },
                    else => j += 1,
                }
            }
            if (j == word_start) return error.Syntax;
            self.pos = j;
        }
        return std.mem.trim(u8, text[start..self.pos], " \t");
    }

    fn parseArith(self: *Parser) Error!Node {
        const close = parser.findParenEnd(self.text, self.pos) orelse return error.Incomplete;
        if (close < self.pos + 3 or self.text[close - 1] != ')') return error.Syntax;
        const expression = self.text[self.pos + 2 .. close - 1];
        self.pos = close + 1;
        return .{ .arith = expression };
    }

    fn parseIf(self: *Parser) Error!Node {
        self.pos += 2;
        var branches = std.ArrayList(Branch).init(self.arena);
        var else_body: ?List = null;
        while (true) {
            const cond = try self.parseList(&.{"then"});
            if (cond.len == 0) return error.Syntax;
            self.pos += 4;
            const body = try self.parseList(&.{ "elif", "else", "fi" });
            if (body.len == 0) return error.Syntax;
            try branches.append(.{ .cond = cond, .body = body });
            const word = self.peekWord();
            if (std.mem.eql(u8, word, "elif")) {
                self.pos += 4;
                continue;
            }
            if (std.mem.eql(u8, word, "else")) {
                self.pos += 4;
                const tail = try self.parseList(&.{"fi"});
                if (tail.len == 0) return error.Syntax;
                else_body = tail;
            }
            self.pos += 2;
            break;
        }
        return .{ .if_clause = .{ .branches = branches.items, .else_body = else_body } };
    }

    fn parseLoop(self: *Parser) Error!Node {
        const until = self.text[self.pos] == 'u';
        self.pos += 5;
        const cond = try self.parseList(&.{"do"});
        if (cond.len == 0) return error.Syntax;
        self.pos += 2;
        const body = try self.parseList(&.{"done"});
        if (body.len == 0) return error.Syntax;
        self.pos += 4;
        return .{ .loop = .{ .until = until, .cond = cond, .body = body } };
    }

    fn parseFor(self: *Parser) Error!Node {
        self.pos += 3;
        self.skipBlanks();
        const name = self.peekWord();
        if (!parser.isName(name)) return if (self.eof()) error.Incomplete else error.Syntax;
        self.pos += name.len;
        self.skipBlanks();
        var words: []const u8 = "";
        if (std.mem.eql(u8, self.peekWord(), "in")) {
            self.pos += 2;
            words = try self.scanSpan();
        }
        self.skipSeparators();
        if (self.eof()) return error.Incomplete;
        if (!std.mem.eql(u8, self.peekWord(), "do")) return error.Syntax;
        self.pos += 2;
        const body = try self.parseList(&.{"done"});
        if (body.len == 0) return error.Syntax;
        self.pos += 4;
        return .{ .for_clause = .{ .name = name, .words = words, .body = body } };
    }

    fn scanSpan(self: *Parser) Error![]const u8 {
        const text = self.text;
        const start = self.pos;
        var i = start;
        scan: while (i < text.len) {
            switch (text[i]) {
                ';', '\n' => break :scan,
                '&' => {
                    if (i + 1 < text.len and text[i + 1] == '&') break :scan;
                    i += 1;
                },
                '|' => {
                    if (i + 1 < text.len and text[i + 1] == '|') break :scan;
                    var j = i + 1;
                    while (j < text.len and std.mem.indexOfScalar(u8, " \t\n", text[j]) != null) j += 1;
                    if (compoundStartsAt(text, j)) break :scan;
                    i += 1;
                },
                '\\' => i = @min(i + 2, text.len),
                '\'' => i = (std.mem.indexOfScalarPos(u8, text, i + 1, '\'') orelse return error.Incomplete) + 1,
                '`' => i = (std.mem.indexOfScalarPos(u8, text, i + 1, '`') orelse return error.Incomplete) + 1,
                '"' => i = try skipDouble(text, i),
                '$' => {
                    if (i + 1 < text.len and text[i + 1] == '(') {
                        i = (parser.findParenEnd(text, i + 1) orelse return error.Incomplete) + 1;
                    } else {
                        i += 1;
                    }
                },
                '#' => {
                    if (i == start or text[i - 1] == ' ' or text[i - 1] == '\t') break :scan;
                    i += 1;
                },
                else => i += 1,
            }
        }
        self.pos = i;
        const span = std.mem.trim(u8, text[start..i], " \t");
        if (span.len == 0 and i >= text.len and start >= text.len) return error.Incomplete;
        if (span.len == 0 and !std.mem.eql(u8, self.peekWordAt(start), "")) return error.Syntax;
        return span;
    }

    fn peekWordAt(self: *Parser, index: usize) []const u8 {
        const saved = self.pos;
        self.pos = index;
        defer self.pos = saved;
        return self.peekWord();
    }
};

fn compoundStartsAt(text: []const u8, index: usize) bool {
    if (std.mem.startsWith(u8, text[index..], "((")) return true;
    var end = index;
    while (end < text.len and std.mem.indexOfScalar(u8, " \t\n;&|<>()'\"`$\\#", text[end]) == null) end += 1;
    const word = text[index..end];
    return std.mem.eql(u8, word, "if") or std.mem.eql(u8, word, "while") or std.mem.eql(u8, word, "until") or std.mem.eql(u8, word, "for");
}

fn skipDouble(text: []const u8, start: usize) Error!usize {
    var i = start + 1;
    while (i < text.len) {
        switch (text[i]) {
            '\\' => i += 2,
            '"' => return i + 1,
            '`' => i = (std.mem.indexOfScalarPos(u8, text, i + 1, '`') orelse return error.Incomplete) + 1,
            '$' => {
                if (i + 1 < text.len and text[i + 1] == '(') {
                    i = (parser.findParenEnd(text, i + 1) orelse return error.Incomplete) + 1;
                } else {
                    i += 1;
                }
            },
            else => i += 1,
        }
    }
    return error.Incomplete;
}

fn isOneOf(set: []const []const u8, word: []const u8) bool {
    for (set) |candidate| {
        if (std.mem.eql(u8, candidate, word)) return true;
    }
    return false;
}
