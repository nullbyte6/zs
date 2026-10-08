const std = @import("std");
const posix = std.posix;

pub const Command = struct {
    argv: []const []const u8,
};

pub const Pipeline = struct {
    commands: []const Command,
};

pub const Error = error{
    UnterminatedQuote,
    UnsupportedOperator,
    MissingCommand,
    BadSubstitution,
    OutOfMemory,
};

pub fn message(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.UnterminatedQuote => "syntax error: unterminated quote",
        error.UnsupportedOperator => "syntax error: '&', '<' and '>' are not supported yet",
        error.MissingCommand => "syntax error: missing command",
        error.BadSubstitution => "syntax error: bad substitution",
        error.OutOfMemory => "out of memory",
        else => null,
    };
}

pub const Parser = struct {
    arena: std.mem.Allocator,
    line: []const u8,
    pos: usize = 0,
    last_status: u8 = 0,
    word: std.ArrayList(u8),
    in_word: bool = false,
    words: std.ArrayList([]const u8),
    commands: std.ArrayList(Command),

    pub fn init(arena: std.mem.Allocator, line: []const u8) Parser {
        return .{
            .arena = arena,
            .line = line,
            .word = .init(arena),
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
                    const end = std.mem.indexOfScalarPos(u8, line, self.pos + 1, '\'') orelse return error.UnterminatedQuote;
                    try self.word.appendSlice(line[self.pos + 1 .. end]);
                    self.in_word = true;
                    self.pos = end + 1;
                },
                '"' => try self.doubleQuoted(),
                '\\' => {
                    if (self.pos + 1 < line.len) {
                        try self.word.append(line[self.pos + 1]);
                        self.pos += 2;
                    } else {
                        try self.word.append('\\');
                        self.pos += 1;
                    }
                    self.in_word = true;
                },
                '$' => try self.expandVariable(false),
                '|' => {
                    try self.endCommand();
                    self.pos += 1;
                },
                ';' => {
                    self.pos += 1;
                    return try self.endPipeline();
                },
                '&', '<', '>' => return error.UnsupportedOperator,
                '~' => {
                    if (!self.in_word and tildeEnds(line, self.pos + 1)) {
                        if (posix.getenv("HOME")) |home| {
                            try self.word.appendSlice(home);
                            self.in_word = true;
                            self.pos += 1;
                            continue;
                        }
                    }
                    try self.word.append('~');
                    self.in_word = true;
                    self.pos += 1;
                },
                else => {
                    try self.word.append(c);
                    self.in_word = true;
                    self.pos += 1;
                },
            }
        }

        try self.flushWord();
        if (self.words.items.len > 0) return try self.endPipeline();
        if (self.commands.items.len > 0) return error.MissingCommand;
        return null;
    }

    fn flushWord(self: *Parser) Error!void {
        if (!self.in_word) return;
        try self.words.append(try self.word.toOwnedSlice());
        self.in_word = false;
    }

    fn endCommand(self: *Parser) Error!void {
        try self.flushWord();
        if (self.words.items.len == 0) return error.MissingCommand;
        try self.commands.append(.{ .argv = try self.words.toOwnedSlice() });
    }

    fn endPipeline(self: *Parser) Error!Pipeline {
        try self.endCommand();
        return .{ .commands = try self.commands.toOwnedSlice() };
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
                try self.word.append(line[self.pos + 1]);
                self.pos += 2;
                continue;
            }
            try self.word.append(c);
            self.pos += 1;
        }
        return error.UnterminatedQuote;
    }

    fn expandVariable(self: *Parser, quoted: bool) Error!void {
        const line = self.line;
        var i = self.pos + 1;
        var value: []const u8 = "";
        if (i < line.len and line[i] == '?') {
            value = try std.fmt.allocPrint(self.arena, "{d}", .{self.last_status});
            i += 1;
        } else if (i < line.len and line[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, line, i + 1, '}') orelse return error.BadSubstitution;
            const name = line[i + 1 .. end];
            if (!isName(name)) return error.BadSubstitution;
            value = posix.getenv(name) orelse "";
            i = end + 1;
        } else {
            var end = i;
            while (end < line.len and isNameChar(line[end], end == i)) end += 1;
            if (end == i) {
                try self.word.append('$');
                self.in_word = true;
                self.pos += 1;
                return;
            }
            value = posix.getenv(line[i..end]) orelse "";
            i = end;
        }
        self.pos = i;

        if (quoted) {
            try self.word.appendSlice(value);
            return;
        }
        for (value) |b| {
            if (b == ' ' or b == '\t' or b == '\n') {
                try self.flushWord();
            } else {
                try self.word.append(b);
                self.in_word = true;
            }
        }
    }
};

fn isNameChar(c: u8, first: bool) bool {
    return c == '_' or std.ascii.isAlphabetic(c) or (!first and std.ascii.isDigit(c));
}

fn isName(name: []const u8) bool {
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
