const std = @import("std");
const commands = @import("commands.zig");
const arith = @import("arith.zig");
const parser = @import("parser.zig");

const reset = "\x1b[0m";
const command_color = "\x1b[33m";
const invalid_color = "\x1b[31m";
const argument_color = "\x1b[34m";
const string_color = "\x1b[36m";
const flag_color = "\x1b[90m";
const symbol_color = "\x1b[96m";
const keyword_color = "\x1b[38;5;135m";
const param_color = "\x1b[31m";
const dollar_color = "\x1b[38;5;208m";

const keywords = [_][]const u8{ "if", "then", "elif", "else", "fi", "while", "until", "do", "done", "for", "case", "esac", "function", "select" };

pub fn render(writer: anytype, line: []const u8) !void {
    if (arith.looksLikeExpression(line)) return writeColored(writer, argument_color, line);
    var i: usize = 0;
    var expect_command = true;
    var after_redirect = false;
    var for_state: u8 = 0;
    var is_case = false;
    var case_depth: usize = 0;
    var in_patterns = false;
    var paren_depth: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (isSpace(c)) {
            try writer.writeByte(c);
            i += 1;
        } else if (isOperator(c)) {
            var end = i;
            while (end < line.len and isOperator(line[end])) end += 1;
            for (line[i..end], i..) |op, index| {
                if (op == '<' or op == '>' or (op == '&' and index + 1 < line.len and line[index + 1] == '>')) {
                    after_redirect = true;
                } else if (!(op == '&' and index > 0 and line[index - 1] == '>')) {
                    expect_command = true;
                }
            }
            if (case_depth > 0 and std.mem.indexOf(u8, line[i..end], ";;") != null) in_patterns = true;
            try writer.writeAll(symbol_color);
            try writer.writeAll(line[i..end]);
            try writer.writeAll(reset);
            i = end;
        } else if (c == '(' and expect_command and i + 1 < line.len and line[i + 1] != '(' and line[i + 1] != ')') {
            try writeColored(writer, flag_color, "(");
            paren_depth += 1;
            i += 1;
        } else if (c == ')' and paren_depth > 0 and !in_patterns) {
            try writeColored(writer, flag_color, ")");
            paren_depth -= 1;
            expect_command = false;
            i += 1;
        } else {
            var end = wordEnd(line, i);
            if (paren_depth > 0 and !in_patterns) {
                var trailing: usize = 0;
                while (end - trailing > i + 1 and line[end - 1 - trailing] == ')') trailing += 1;
                const opens = std.mem.count(u8, line[i..end], "(");
                const closes = std.mem.count(u8, line[i..end], ")");
                end -= @min(trailing, if (closes > opens) closes - opens else 0);
            }
            const word = line[i..end];
            if (end < line.len and (line[end] == '<' or line[end] == '>') and isDigits(word)) {
                try writer.writeAll(symbol_color);
                try writer.writeAll(word);
                try writer.writeAll(reset);
            } else if (in_patterns) {
                if (std.mem.eql(u8, word, "esac")) {
                    try writeColored(writer, keyword_color, word);
                    in_patterns = false;
                    if (case_depth > 0) case_depth -= 1;
                    expect_command = false;
                } else {
                    try renderWord(writer, word, argument_color);
                    if (std.mem.indexOfScalar(u8, word, ')') != null) {
                        in_patterns = false;
                        expect_command = true;
                    }
                }
            } else if (after_redirect) {
                try renderWord(writer, word, argument_color);
                after_redirect = false;
            } else if (expect_command and isKeyword(word)) {
                try writeColored(writer, keyword_color, word);
                if (std.mem.eql(u8, word, "for") or std.mem.eql(u8, word, "case") or std.mem.eql(u8, word, "select")) {
                    expect_command = false;
                    for_state = 1;
                    is_case = std.mem.eql(u8, word, "case");
                } else if (std.mem.eql(u8, word, "function")) {
                    expect_command = false;
                    for_state = 3;
                } else if (std.mem.eql(u8, word, "esac") and case_depth > 0) {
                    case_depth -= 1;
                }
            } else if (for_state == 3) {
                try renderWord(writer, word, command_color);
                for_state = 0;
                expect_command = true;
            } else if (for_state == 1) {
                try renderWord(writer, word, argument_color);
                for_state = 2;
            } else if (for_state == 2 and std.mem.eql(u8, word, "in")) {
                try writeColored(writer, keyword_color, word);
                for_state = 0;
                if (is_case) {
                    case_depth += 1;
                    in_patterns = true;
                }
            } else if (std.mem.eql(u8, word, "()")) {
                try renderWord(writer, word, argument_color);
            } else if (expect_command and std.mem.eql(u8, word, "{")) {
                try renderWord(writer, word, argument_color);
            } else if (expect_command and definesFunction(line, i, end)) {
                try renderWord(writer, word, command_color);
            } else if (expect_command and std.mem.startsWith(u8, word, "((")) {
                try renderWord(writer, word, argument_color);
                expect_command = false;
            } else if (expect_command and isAssignment(word)) {
                try renderWord(writer, word, argument_color);
            } else if (!expect_command and isSymbolWord(word)) {
                try writer.writeAll(symbol_color);
                try writer.writeAll(word);
                try writer.writeAll(reset);
            } else {
                const color = if (expect_command) commandColor(word) else if (c == '-') flag_color else argument_color;
                try renderWord(writer, word, color);
                expect_command = false;
            }
            i = end;
        }
    }
}

fn definesFunction(line: []const u8, start: usize, end: usize) bool {
    const word = line[start..end];
    if (std.mem.endsWith(u8, word, "()")) return parser.isFunctionName(word[0 .. word.len - 2]);
    if (!parser.isFunctionName(word)) return false;
    var i = end;
    while (i < line.len and isSpace(line[i])) i += 1;
    if (i >= line.len or line[i] != '(') return false;
    i += 1;
    while (i < line.len and isSpace(line[i])) i += 1;
    return i < line.len and line[i] == ')';
}

fn isKeyword(word: []const u8) bool {
    for (keywords) |keyword| {
        if (std.mem.eql(u8, keyword, word)) return true;
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

fn isSymbolWord(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |c| {
        if (std.mem.indexOfScalar(u8, "+-*/%=^!~", c) == null) return false;
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

fn commandColor(word: []const u8) []const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const name = unquote(&buf, word) orelse return invalid_color;
    return if (commands.exists(name)) command_color else invalid_color;
}

fn wordEnd(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len and !isSpace(line[i]) and !isOperator(line[i])) {
        switch (line[i]) {
            '$' => i = if (i + 1 < line.len and line[i + 1] == '(')
                (if (parser.findParenEnd(line, i + 1)) |close| close + 1 else line.len)
            else if (i + 1 < line.len and line[i + 1] == '{')
                (if (parser.findBraceEnd(line, i + 1)) |close| close + 1 else line.len)
            else
                i + 1,
            '`' => i = if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |close| close + 1 else line.len,
            '\'', '"' => i = quoteEnd(line, i),
            '\\' => i += if (i + 1 < line.len) 2 else 1,
            else => i += 1,
        }
    }
    return i;
}

fn renderWord(writer: anytype, word: []const u8, color: []const u8) !void {
    var i: usize = 0;
    while (i < word.len) {
        const quoted = word[i] == '\'' or word[i] == '"';
        var end = i;
        if (quoted) {
            end = quoteEnd(word, i);
            try writer.writeAll(string_color);
            try writer.writeAll(word[i..end]);
            try writer.writeAll(reset);
        } else {
            while (end < word.len and word[end] != '\'' and word[end] != '"') {
                end += if (word[end] == '\\' and end + 1 < word.len) 2 else 1;
            }
            try renderPlain(writer, word, i, end, color);
        }
        i = end;
    }
}

fn renderPlain(writer: anytype, word: []const u8, start: usize, end: usize, color: []const u8) !void {
    var run = start;
    var i = start;
    while (i < end) {
        const c = word[i];
        if (c == '\\' and i + 1 < end) {
            i += 2;
            continue;
        }
        if (c == '$') {
            const tail = word[i + 1 .. end];
            var consumed: usize = 0;
            if (tail.len > 0 and tail[0] == '{') {
                const close = std.mem.indexOfScalar(u8, tail, '}');
                if (close != null and isSpecialParam(tail[1..close.?])) {
                    if (run < i) try writeColored(writer, color, word[run..i]);
                    try writeColored(writer, dollar_color, "$");
                    try writeColored(writer, flag_color, "{");
                    try writeColored(writer, param_color, tail[1..close.?]);
                    try writeColored(writer, flag_color, "}");
                    consumed = close.? + 2;
                }
            } else if (tail.len > 0 and (std.ascii.isDigit(tail[0]) or std.mem.indexOfScalar(u8, "@*#?$", tail[0]) != null)) {
                if (run < i) try writeColored(writer, color, word[run..i]);
                try writeColored(writer, param_color, word[i .. i + 2]);
                consumed = 2;
            }
            if (consumed == 0 and (tail.len == 0 or !(tail[0] == '_' or std.ascii.isAlphabetic(tail[0])))) {
                if (run < i) try writeColored(writer, color, word[run..i]);
                try writeColored(writer, dollar_color, "$");
                consumed = 1;
            }
            if (consumed > 0) {
                i += consumed;
                run = i;
                continue;
            }
        }
        const wildcard = c == '*' or (c == '?' and !(i > 0 and word[i - 1] == '$'));
        const bracket = std.mem.indexOfScalar(u8, "(){}[]", c) != null;
        if (!wildcard and !bracket) {
            i += 1;
            continue;
        }
        if (run < i) try writeColored(writer, color, word[run..i]);
        try writeColored(writer, if (bracket) flag_color else symbol_color, word[i .. i + 1]);
        i += 1;
        run = i;
    }
    if (run < end) try writeColored(writer, color, word[run..end]);
}

fn isSpecialParam(name: []const u8) bool {
    if (name.len == 1 and std.mem.indexOfScalar(u8, "@*#?$", name[0]) != null) return true;
    return isDigits(name);
}

fn writeColored(writer: anytype, color: []const u8, text: []const u8) !void {
    try writer.writeAll(color);
    try writer.writeAll(text);
    try writer.writeAll(reset);
}

fn unquote(buf: []u8, word: []const u8) ?[]const u8 {
    var len: usize = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < word.len) : (i += 1) {
        const c = word[i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
                continue;
            }
            if (quote == '"' and c == '\\' and i + 1 < word.len) i += 1;
        } else if (c == '\'' or c == '"') {
            quote = c;
            continue;
        } else if (c == '\\' and i + 1 < word.len) {
            i += 1;
        }
        if (len == buf.len) return null;
        buf[len] = word[i];
        len += 1;
    }
    return buf[0..len];
}

fn quoteEnd(line: []const u8, start: usize) usize {
    const quote = line[start];
    var i = start + 1;
    while (i < line.len) {
        if (line[i] == quote) return i + 1;
        i += if (quote == '"' and line[i] == '\\' and i + 1 < line.len) 2 else 1;
    }
    return line.len;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isOperator(c: u8) bool {
    return c == '|' or c == ';' or c == '&' or c == '<' or c == '>';
}
