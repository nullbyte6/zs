const std = @import("std");
const posix = std.posix;
const completion = @import("complete.zig");
const highlight = @import("highlight.zig");
const unicode = @import("unicode.zig");

const Position = struct {
    row: usize = 0,
    col: usize = 0,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    history: std.ArrayList([]u8),
    history_pos: usize = 0,
    draft: ?[]u8 = null,
    cursor: usize = 0,
    cursor_row: usize = 0,
    prompt: []const u8,

    pub fn init(allocator: std.mem.Allocator, prompt: []const u8) Editor {
        return .{
            .allocator = allocator,
            .buffer = .init(allocator),
            .history = .init(allocator),
            .prompt = prompt,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit();
        self.clearDraft();
    }

    pub fn addHistory(self: *Editor, line: []const u8) !void {
        if (self.history.getLastOrNull()) |last| {
            if (std.mem.eql(u8, last, line)) return;
        }
        const copy = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(copy);
        try self.history.append(copy);
    }

    pub fn readLine(self: *Editor) !?[]const u8 {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.cursor_row = 0;
        self.history_pos = self.history.items.len;
        self.clearDraft();

        const original = posix.tcgetattr(posix.STDIN_FILENO) catch |err| switch (err) {
            error.NotATerminal => return self.readPlain(),
            else => return err,
        };

        var raw = original;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw);
        defer posix.tcsetattr(posix.STDIN_FILENO, .NOW, original) catch {};

        return self.readRaw();
    }

    fn readPlain(self: *Editor) !?[]const u8 {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(self.prompt);
        std.io.getStdIn().reader().streamUntilDelimiter(self.buffer.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => {
                try stdout.writeAll("\n");
                return null;
            },
            else => return err,
        };
        return self.buffer.items;
    }

    fn readRaw(self: *Editor) !?[]const u8 {
        const stdout = std.io.getStdOut().writer();
        try self.redraw();
        while (true) {
            const byte = readByte() catch |err| switch (err) {
                error.EndOfStream => {
                    try stdout.writeAll("\r\n");
                    return null;
                },
                else => return err,
            };
            switch (byte) {
                '\r', '\n' => {
                    try self.finishLine();
                    try stdout.writeAll("\r\n");
                    return self.buffer.items;
                },
                3 => {
                    try self.finishLine();
                    try stdout.writeAll("^C\r\n");
                    self.buffer.clearRetainingCapacity();
                    self.cursor = 0;
                    return self.buffer.items;
                },
                4 => {
                    if (self.buffer.items.len == 0) {
                        try stdout.writeAll("\r\n");
                        return null;
                    }
                    try self.deleteForward();
                },
                1 => self.cursor = 0,
                9 => try self.complete(),
                12 => {
                    try stdout.writeAll("\x1b[H\x1b[2J");
                    self.cursor_row = 0;
                },
                14 => try self.historyNext(),
                16 => try self.historyPrevious(),
                5 => self.cursor = self.buffer.items.len,
                2 => self.cursor = prevBoundary(self.buffer.items, self.cursor),
                6 => self.cursor = nextBoundary(self.buffer.items, self.cursor),
                11 => self.buffer.shrinkRetainingCapacity(self.cursor),
                21 => try self.deleteRange(0, self.cursor),
                23 => try self.deleteWordBackward(),
                8, 127 => try self.deleteBackward(),
                27 => try self.handleEscape(),
                0x20...0x7e => try self.insert(&.{byte}),
                0xc0...0xff => try self.insertUtf8(byte),
                else => {},
            }
            try self.redraw();
        }
    }

    fn complete(self: *Editor) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const result = (try completion.complete(arena.allocator(), self.buffer.items, self.cursor)) orelse return;
        const candidates = result.candidates;
        if (candidates.len == 0) return;

        var common = candidates[0].text;
        for (candidates[1..]) |candidate| {
            var len: usize = 0;
            while (len < common.len and len < candidate.text.len and common[len] == candidate.text[len]) len += 1;
            common = common[0..len];
        }
        while (common.len > 0 and common.len < candidates[0].text.len and (candidates[0].text[common.len] & 0xc0) == 0x80) {
            common = common[0 .. common.len - 1];
        }
        var slashes: usize = 0;
        while (slashes < common.len and common[common.len - 1 - slashes] == '\\') slashes += 1;
        if (slashes % 2 == 1) common = common[0 .. common.len - 1];

        if (candidates.len == 1) {
            const suffix: []const u8 = if (candidates[0].is_dir) "" else " ";
            const text = try std.fmt.allocPrint(arena.allocator(), "{s}{s}", .{ candidates[0].text, suffix });
            try self.replaceWord(result.start, text);
        } else if (common.len > result.typed.len) {
            try self.replaceWord(result.start, common);
        } else {
            try self.listCandidates(candidates);
        }
    }

    fn replaceWord(self: *Editor, start: usize, text: []const u8) !void {
        try self.buffer.replaceRange(start, self.cursor - start, text);
        self.cursor = start + text.len;
    }

    fn listCandidates(self: *Editor, candidates: []const completion.Candidate) !void {
        const stdout = std.io.getStdOut().writer();
        const cols = terminalColumns();
        const saved = self.cursor;
        self.cursor = self.buffer.items.len;
        try self.redraw();
        self.cursor = saved;
        try stdout.writeAll("\r\n");

        var widest: usize = 0;
        for (candidates) |candidate| widest = @max(widest, displayWidth(candidate.label));
        const cell = widest + 2;
        const per_row = @max(1, cols / cell);
        const rows = (candidates.len + per_row - 1) / per_row;
        var bw = std.io.bufferedWriter(stdout);
        const w = bw.writer();
        for (0..rows) |row| {
            for (0..per_row) |column| {
                const index = column * rows + row;
                if (index >= candidates.len) break;
                const label = candidates[index].label;
                try w.writeAll(label);
                if (index + rows < candidates.len) {
                    for (0..cell - displayWidth(label)) |_| try w.writeByte(' ');
                }
            }
            try w.writeAll("\r\n");
        }
        try bw.flush();
        self.cursor_row = 0;
    }

    fn clearDraft(self: *Editor) void {
        if (self.draft) |draft| self.allocator.free(draft);
        self.draft = null;
    }

    fn loadLine(self: *Editor, text: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(text);
        self.cursor = self.buffer.items.len;
    }

    fn historyPrevious(self: *Editor) !void {
        if (self.history_pos == 0) return;
        if (self.history_pos == self.history.items.len) {
            self.clearDraft();
            self.draft = try self.allocator.dupe(u8, self.buffer.items);
        }
        self.history_pos -= 1;
        try self.loadLine(self.history.items[self.history_pos]);
    }

    fn historyNext(self: *Editor) !void {
        if (self.history_pos >= self.history.items.len) return;
        self.history_pos += 1;
        if (self.history_pos == self.history.items.len) {
            try self.loadLine(self.draft orelse "");
        } else {
            try self.loadLine(self.history.items[self.history_pos]);
        }
    }

    fn insert(self: *Editor, bytes: []const u8) !void {
        try self.buffer.insertSlice(self.cursor, bytes);
        self.cursor += bytes.len;
    }

    fn insertUtf8(self: *Editor, lead: u8) !void {
        const len: usize = if (lead < 0xe0) 2 else if (lead < 0xf0) 3 else 4;
        var seq: [4]u8 = undefined;
        seq[0] = lead;
        for (seq[1..len]) |*b| b.* = try readByte();
        try self.insert(seq[0..len]);
    }

    fn deleteRange(self: *Editor, start: usize, end: usize) !void {
        try self.buffer.replaceRange(start, end - start, &.{});
        self.cursor = start;
    }

    fn deleteBackward(self: *Editor) !void {
        const start = prevBoundary(self.buffer.items, self.cursor);
        try self.deleteRange(start, self.cursor);
    }

    fn deleteForward(self: *Editor) !void {
        const end = nextBoundary(self.buffer.items, self.cursor);
        try self.deleteRange(self.cursor, end);
    }

    fn deleteWordBackward(self: *Editor) !void {
        const items = self.buffer.items;
        var start = self.cursor;
        while (start > 0 and items[start - 1] == ' ') start -= 1;
        while (start > 0 and items[start - 1] != ' ') start -= 1;
        try self.deleteRange(start, self.cursor);
    }

    fn handleEscape(self: *Editor) !void {
        if (!try inputPending()) return;
        const intro = try readByte();
        if (intro == 'O') {
            switch (try readByte()) {
                'H' => self.cursor = 0,
                'F' => self.cursor = self.buffer.items.len,
                else => {},
            }
            return;
        }
        if (intro != '[') return;

        var params: [8]u8 = undefined;
        var params_len: usize = 0;
        const final = while (true) {
            const b = try readByte();
            if (b >= 0x40 and b <= 0x7e) break b;
            if (params_len < params.len) {
                params[params_len] = b;
                params_len += 1;
            }
        };
        const param = params[0..params_len];

        switch (final) {
            'A' => try self.historyPrevious(),
            'B' => try self.historyNext(),
            'C' => self.cursor = nextBoundary(self.buffer.items, self.cursor),
            'D' => self.cursor = prevBoundary(self.buffer.items, self.cursor),
            'H' => self.cursor = 0,
            'F' => self.cursor = self.buffer.items.len,
            '~' => {
                if (std.mem.eql(u8, param, "3")) {
                    try self.deleteForward();
                } else if (std.mem.eql(u8, param, "1") or std.mem.eql(u8, param, "7")) {
                    self.cursor = 0;
                } else if (std.mem.eql(u8, param, "4") or std.mem.eql(u8, param, "8")) {
                    self.cursor = self.buffer.items.len;
                }
            },
            else => {},
        }
    }

    fn finishLine(self: *Editor) !void {
        self.cursor = self.buffer.items.len;
        try self.redraw();
    }

    fn redraw(self: *Editor) !void {
        const cols = terminalColumns();
        var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
        const w = bw.writer();

        if (self.cursor_row > 0) try w.print("\x1b[{d}A", .{self.cursor_row});
        try w.writeAll("\r\x1b[J");
        try w.writeAll(self.prompt);
        try highlight.render(w, self.buffer.items);

        var end = Position{};
        advance(&end, self.prompt, cols);
        advance(&end, self.buffer.items, cols);
        if (end.col == cols) {
            try w.writeAll("\r\n");
            end = .{ .row = end.row + 1 };
        }

        var target = Position{};
        advance(&target, self.prompt, cols);
        advance(&target, self.buffer.items[0..self.cursor], cols);
        if (target.col == cols) target = .{ .row = target.row + 1 };

        if (end.row > target.row) try w.print("\x1b[{d}A", .{end.row - target.row});
        try w.writeAll("\r");
        if (target.col > 0) try w.print("\x1b[{d}C", .{target.col});
        self.cursor_row = target.row;
        try bw.flush();
    }
};

fn readByte() !u8 {
    return std.io.getStdIn().reader().readByte();
}

fn inputPending() !bool {
    var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
    return (try posix.poll(&fds, 50)) > 0;
}

fn advance(pos: *Position, text: []const u8, cols: usize) void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and (text[i] < 0x40 or text[i] > 0x7e)) i += 1;
            i += 1;
            continue;
        }
        const glyph = unicode.glyphAt(text, i);
        i += glyph.len;
        if (glyph.width == 0) continue;
        if (pos.col + glyph.width > cols) pos.* = .{ .row = pos.row + 1 };
        pos.col += glyph.width;
    }
}

fn displayWidth(text: []const u8) usize {
    var pos = Position{};
    advance(&pos, text, std.math.maxInt(usize));
    return pos.col;
}

fn terminalColumns() usize {
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) != .SUCCESS or ws.col < 2) return 80;
    return ws.col;
}

fn prevBoundary(items: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and items[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

fn nextBoundary(items: []const u8, pos: usize) usize {
    if (pos >= items.len) return items.len;
    var i = pos + 1;
    while (i < items.len and items[i] & 0xc0 == 0x80) i += 1;
    return i;
}
