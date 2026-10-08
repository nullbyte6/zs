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

pub const Node = union(enum) {
    simple: []const u8,
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
            const node = try self.parseCommand();
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
