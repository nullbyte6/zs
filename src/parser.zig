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
    OutOfMemory,
};

pub fn message(err: Error) []const u8 {
    return switch (err) {
        error.UnterminatedQuote => "syntax error: unterminated quote",
        error.UnsupportedOperator => "syntax error: '&', '<' and '>' are not supported yet",
        error.MissingCommand => "syntax error: missing command",
        error.OutOfMemory => "out of memory",
    };
}

pub fn parse(arena: std.mem.Allocator, line: []const u8) Error![]const Pipeline {
    var p = Parser{
        .word = .init(arena),
        .words = .init(arena),
        .commands = .init(arena),
        .pipelines = .init(arena),
    };
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        switch (c) {
            ' ', '\t' => {
                try p.flushWord();
                i += 1;
            },
            '\'' => {
                const end = std.mem.indexOfScalarPos(u8, line, i + 1, '\'') orelse return error.UnterminatedQuote;
                try p.word.appendSlice(line[i + 1 .. end]);
                p.in_word = true;
                i = end + 1;
            },
            '"' => i = try p.doubleQuoted(line, i),
            '\\' => {
                if (i + 1 < line.len) {
                    try p.word.append(line[i + 1]);
                    i += 2;
                } else {
                    try p.word.append('\\');
                    i += 1;
                }
                p.in_word = true;
            },
            '|' => {
                try p.endCommand();
                i += 1;
            },
            ';' => {
                try p.endCommand();
                try p.endPipeline();
                i += 1;
            },
            '&', '<', '>' => return error.UnsupportedOperator,
            '~' => {
                if (!p.in_word and tildeEnds(line, i + 1)) {
                    if (posix.getenv("HOME")) |home| {
                        try p.word.appendSlice(home);
                        p.in_word = true;
                        i += 1;
                        continue;
                    }
                }
                try p.word.append('~');
                p.in_word = true;
                i += 1;
            },
            else => {
                try p.word.append(c);
                p.in_word = true;
                i += 1;
            },
        }
    }

    try p.flushWord();
    if (p.words.items.len > 0) {
        try p.endCommand();
    } else if (p.commands.items.len > 0) {
        return error.MissingCommand;
    }
    if (p.commands.items.len > 0) try p.endPipeline();
    return p.pipelines.toOwnedSlice();
}

const Parser = struct {
    word: std.ArrayList(u8),
    in_word: bool = false,
    words: std.ArrayList([]const u8),
    commands: std.ArrayList(Command),
    pipelines: std.ArrayList(Pipeline),

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

    fn endPipeline(self: *Parser) Error!void {
        try self.pipelines.append(.{ .commands = try self.commands.toOwnedSlice() });
    }

    fn doubleQuoted(self: *Parser, line: []const u8, start: usize) Error!usize {
        self.in_word = true;
        var i = start + 1;
        while (i < line.len) {
            const c = line[i];
            if (c == '"') return i + 1;
            if (c == '\\' and i + 1 < line.len and std.mem.indexOfScalar(u8, "\"\\$`", line[i + 1]) != null) {
                try self.word.append(line[i + 1]);
                i += 2;
                continue;
            }
            try self.word.append(c);
            i += 1;
        }
        return error.UnterminatedQuote;
    }
};

fn tildeEnds(line: []const u8, index: usize) bool {
    if (index >= line.len) return true;
    return switch (line[index]) {
        ' ', '\t', '/', '|', ';' => true,
        else => false,
    };
}
