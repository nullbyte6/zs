const std = @import("std");

const reset = "\x1b[0m";
const command_color = "\x1b[33m";
const argument_color = "\x1b[34m";
const string_color = "\x1b[36m";
const flag_color = "\x1b[90m";

pub fn render(writer: anytype, line: []const u8) !void {
    var i: usize = 0;
    var expect_command = true;
    while (i < line.len) {
        const c = line[i];
        if (isSpace(c)) {
            try writer.writeByte(c);
            i += 1;
        } else if (isOperator(c)) {
            try writer.writeByte(c);
            expect_command = true;
            i += 1;
        } else {
            const color = if (expect_command) command_color else if (c == '-') flag_color else argument_color;
            i = try renderWord(writer, line, i, color);
            expect_command = false;
        }
    }
}

fn renderWord(writer: anytype, line: []const u8, start: usize, color: []const u8) !usize {
    var i = start;
    while (i < line.len and !isSpace(line[i]) and !isOperator(line[i])) {
        const c = line[i];
        if (c == '\'' or c == '"') {
            const end = quoteEnd(line, i);
            try writer.writeAll(string_color);
            try writer.writeAll(line[i..end]);
            try writer.writeAll(reset);
            i = end;
        } else {
            var end = i;
            while (end < line.len and !isSpace(line[end]) and !isOperator(line[end]) and line[end] != '\'' and line[end] != '"') {
                end += if (line[end] == '\\' and end + 1 < line.len) 2 else 1;
            }
            try writer.writeAll(color);
            try writer.writeAll(line[i..end]);
            try writer.writeAll(reset);
            i = end;
        }
    }
    return i;
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
    return c == '|' or c == ';' or c == '&';
}
