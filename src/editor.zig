const std = @import("std");
const posix = std.posix;
const completion = @import("complete.zig");
const highlight = @import("highlight.zig");
const history = @import("history.zig");
const spec = @import("spec.zig");
const unicode = @import("unicode.zig");
const sys = @import("sys.zig");

const Cycle = struct {
    items: [][]u8,
    start: usize,
    len: usize,
    index: usize,
};

const Position = struct {
    row: usize = 0,
    col: usize = 0,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    history_pos: usize = 0,
    draft: ?[]u8 = null,
    cursor: usize = 0,
    cursor_row: usize = 0,
    marks: bool = false,
    prompt: []const u8,
    cycle: ?Cycle = null,
    cycle_keep: bool = false,
    ghost_text: std.ArrayList(u8),
    ghost_insert: std.ArrayList(u8),
    ghost_back: usize = 0,

    pub fn init(allocator: std.mem.Allocator, prompt: []const u8) Editor {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .prompt = prompt,
            .ghost_text = .empty,
            .ghost_insert = .empty,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit(self.allocator);
        self.ghost_text.deinit(self.allocator);
        self.ghost_insert.deinit(self.allocator);
        self.clearCycle();
        self.clearDraft();
    }

    pub fn addHistory(self: *Editor, line: []const u8) !void {
        _ = self;
        try history.add(line);
    }

    pub fn readLine(self: *Editor) !?[]const u8 {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.cursor_row = 0;
        self.history_pos = history.entries.items.len;
        self.clearDraft();
        self.clearCycle();

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
        const stdout = sys.stdout();
        try sys.writeAll(stdout, self.prompt);
        while (true) {
            const byte = readByte() catch |err| switch (err) {
                error.EndOfStream => {
                    if (self.buffer.items.len > 0) return self.buffer.items;
                    try sys.writeAll(stdout, "\n");
                    return null;
                },
                else => return err,
            };
            if (byte == '\n') return self.buffer.items;
            try self.buffer.append(self.allocator, byte);
        }
    }

    fn readRaw(self: *Editor) !?[]const u8 {
        const stdout = sys.stdout();
        try self.redraw();
        while (true) {
            const byte = readByte() catch |err| switch (err) {
                error.EndOfStream => {
                    try sys.writeAll(stdout, "\r\n");
                    return null;
                },
                else => return err,
            };
            self.cycle_keep = false;
            switch (byte) {
                '\r', '\n' => {
                    try self.finishLine();
                    try sys.writeAll(stdout, "\r\n");
                    if (self.marks) try sys.writeAll(stdout, "\x1b]133;C\x07");
                    return self.buffer.items;
                },
                3 => {
                    try self.finishLine();
                    try sys.writeAll(stdout, "^C\r\n");
                    self.buffer.clearRetainingCapacity();
                    self.cursor = 0;
                    return self.buffer.items;
                },
                4 => {
                    if (self.buffer.items.len == 0) {
                        try sys.writeAll(stdout, "\r\n");
                        return null;
                    }
                    try self.deleteForward();
                },
                1 => self.cursor = 0,
                9 => try self.cycleComplete(true),
                12 => {
                    try sys.writeAll(stdout, "\x1b[H\x1b[2J");
                    self.cursor_row = 0;
                },
                14 => try self.historyNext(),
                16 => try self.historyPrevious(),
                5 => try self.cursorEnd(),
                2 => self.cursor = prevBoundary(self.buffer.items, self.cursor),
                6 => try self.cursorRight(),
                11 => self.buffer.shrinkRetainingCapacity(self.cursor),
                21 => try self.deleteRange(0, self.cursor),
                23 => try self.deleteWordBackward(),
                8, 127 => try self.deleteBackward(),
                27 => try self.handleEscape(),
                0x20...0x7e => try self.insert(&.{byte}),
                0xc0...0xff => try self.insertUtf8(byte),
                else => {},
            }
            if (!self.cycle_keep) self.clearCycle();
            try self.redraw();
        }
    }

    fn cycleComplete(self: *Editor, forward: bool) !void {
        self.cycle_keep = true;
        if (self.cycle == null) {
            spec.invalidate();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const result = (try completion.complete(arena.allocator(), self.buffer.items, self.cursor)) orelse return;
            const candidates = result.candidates;
            if (candidates.len == 0) return;

            const items = try self.allocator.alloc([]u8, candidates.len + 1);
            var made: usize = 0;
            errdefer {
                for (items[0..made]) |item| self.allocator.free(item);
                self.allocator.free(items);
            }
            for (candidates, 0..) |candidate, index| {
                items[index] = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ candidate.text, candidate.suffix });
                made += 1;
            }
            items[candidates.len] = try self.allocator.dupe(u8, self.buffer.items[result.start..self.cursor]);
            self.cycle = .{
                .items = items,
                .start = result.start,
                .len = self.cursor - result.start,
                .index = if (forward) 0 else candidates.len - 1,
            };
            self.applyCycle();
            if (candidates.len == 1) {
                self.clearCycle();
                self.cycle_keep = false;
            }
            return;
        }
        const cycle = &self.cycle.?;
        const total = cycle.items.len;
        cycle.index = if (forward) (cycle.index + 1) % total else (cycle.index + total - 1) % total;
        self.applyCycle();
    }

    fn applyCycle(self: *Editor) void {
        const cycle = &self.cycle.?;
        const text = cycle.items[cycle.index];
        self.buffer.replaceRange(self.allocator, cycle.start, cycle.len, text) catch return;
        cycle.len = text.len;
        self.cursor = cycle.start + text.len;
    }

    fn clearCycle(self: *Editor) void {
        const cycle = self.cycle orelse return;
        for (cycle.items) |item| self.allocator.free(item);
        self.allocator.free(cycle.items);
        self.cycle = null;
    }

    fn refreshGhost(self: *Editor) !void {
        self.ghost_text.clearRetainingCapacity();
        self.ghost_insert.clearRetainingCapacity();
        self.ghost_back = 0;
        const typed = self.buffer.items;
        if (self.cycle != null or typed.len == 0 or self.cursor != typed.len or self.history_pos != history.entries.items.len) return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        if (try completion.complete(arena.allocator(), typed, self.cursor)) |result| {
            if (try self.completionGhost(result)) return;
        }
        if (completion.hint(typed, self.cursor)) |hint| {
            if (hint.quoted) {
                try self.ghost_text.print(self.allocator, "\"{s}\"", .{hint.label});
                try self.ghost_insert.appendSlice(self.allocator, "\"\"");
                self.ghost_back = 1;
            } else {
                try self.ghost_text.print(self.allocator, "<{s}>", .{hint.label});
            }
            return;
        }
        if (self.suggestion()) |rest| {
            try self.ghost_text.appendSlice(self.allocator, rest);
            try self.ghost_insert.appendSlice(self.allocator, rest);
        }
    }

    fn completionGhost(self: *Editor, result: completion.Result) !bool {
        if (result.typed.len == 0) return false;
        var first: ?completion.Candidate = null;
        for (result.candidates) |candidate| {
            if (std.mem.eql(u8, candidate.text, result.typed)) return false;
            if (first == null and candidate.text.len > result.typed.len and std.mem.startsWith(u8, candidate.text, result.typed)) first = candidate;
        }
        const chosen = first orelse return false;
        const rest = chosen.text[result.typed.len..];
        try self.ghost_text.appendSlice(self.allocator, rest);
        try self.ghost_insert.appendSlice(self.allocator, rest);
        try self.ghost_insert.appendSlice(self.allocator, chosen.suffix);
        return true;
    }

    fn suggestion(self: *const Editor) ?[]const u8 {
        const typed = self.buffer.items;
        if (typed.len == 0 or self.cursor != typed.len or self.history_pos != history.entries.items.len) return null;
        var i = history.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = history.entries.items[i];
            if (entry.len > typed.len and std.mem.startsWith(u8, entry, typed) and std.mem.indexOfScalar(u8, entry, '\n') == null) {
                return entry[typed.len..];
            }
        }
        return null;
    }

    fn acceptSuggestion(self: *Editor) !void {
        if (self.ghost_insert.items.len == 0) return;
        try self.buffer.appendSlice(self.allocator, self.ghost_insert.items);
        self.cursor = self.buffer.items.len - self.ghost_back;
    }

    fn acceptSuggestionWord(self: *Editor) !void {
        const pending = self.ghost_insert.items;
        if (pending.len == 0) return;
        var end = wordRight(pending, 0);
        if (end == 0 or self.ghost_back > 0) end = pending.len;
        try self.buffer.appendSlice(self.allocator, pending[0..end]);
        self.cursor = self.buffer.items.len - if (end == pending.len) self.ghost_back else 0;
    }

    fn moveWordRight(self: *Editor) !void {
        if (self.cursor >= self.buffer.items.len) return self.acceptSuggestionWord();
        self.cursor = wordRight(self.buffer.items, self.cursor);
    }

    fn deleteWordBackwardStop(self: *Editor) !void {
        try self.deleteRange(wordLeft(self.buffer.items, self.cursor), self.cursor);
    }

    fn deleteWordForward(self: *Editor) !void {
        try self.deleteRange(self.cursor, wordRight(self.buffer.items, self.cursor));
    }

    fn cursorRight(self: *Editor) !void {
        if (self.cursor >= self.buffer.items.len) return self.acceptSuggestion();
        self.cursor = nextBoundary(self.buffer.items, self.cursor);
    }

    fn cursorEnd(self: *Editor) !void {
        if (self.cursor == self.buffer.items.len) return self.acceptSuggestion();
        self.cursor = self.buffer.items.len;
    }

    fn clearDraft(self: *Editor) void {
        if (self.draft) |draft| self.allocator.free(draft);
        self.draft = null;
    }

    fn loadLine(self: *Editor, text: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, text);
        self.cursor = self.buffer.items.len;
    }

    fn historyPrevious(self: *Editor) !void {
        if (self.history_pos == 0) return;
        if (self.history_pos == history.entries.items.len) {
            self.clearDraft();
            self.draft = try self.allocator.dupe(u8, self.buffer.items);
        }
        self.history_pos -= 1;
        try self.loadLine(history.entries.items[self.history_pos]);
    }

    fn historyNext(self: *Editor) !void {
        if (self.history_pos >= history.entries.items.len) return;
        self.history_pos += 1;
        if (self.history_pos == history.entries.items.len) {
            try self.loadLine(self.draft orelse "");
        } else {
            try self.loadLine(history.entries.items[self.history_pos]);
        }
    }

    fn insert(self: *Editor, bytes: []const u8) !void {
        try self.buffer.insertSlice(self.allocator, self.cursor, bytes);
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
        try self.buffer.replaceRange(self.allocator, start, end - start, &.{});
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
                'F' => try self.cursorEnd(),
                else => {},
            }
            return;
        }
        if (intro != '[') {
            switch (intro) {
                127, 8 => try self.deleteWordBackwardStop(),
                'b' => self.cursor = wordLeft(self.buffer.items, self.cursor),
                'f' => try self.moveWordRight(),
                'd' => try self.deleteWordForward(),
                else => {},
            }
            return;
        }

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
        const by_word = std.mem.endsWith(u8, param, ";3") or std.mem.endsWith(u8, param, ";5") or std.mem.endsWith(u8, param, ";7");

        switch (final) {
            'A' => try self.historyPrevious(),
            'B' => try self.historyNext(),
            'C' => if (by_word) try self.moveWordRight() else try self.cursorRight(),
            'D' => self.cursor = if (by_word) wordLeft(self.buffer.items, self.cursor) else prevBoundary(self.buffer.items, self.cursor),
            'Z' => try self.cycleComplete(false),
            'H' => self.cursor = 0,
            'F' => try self.cursorEnd(),
            '~' => {
                if (std.mem.eql(u8, param, "3")) {
                    try self.deleteForward();
                } else if (std.mem.eql(u8, param, "3;3") or std.mem.eql(u8, param, "3;5")) {
                    try self.deleteWordForward();
                } else if (std.mem.eql(u8, param, "1") or std.mem.eql(u8, param, "7")) {
                    self.cursor = 0;
                } else if (std.mem.eql(u8, param, "4") or std.mem.eql(u8, param, "8")) {
                    try self.cursorEnd();
                }
            },
            else => {},
        }
    }

    fn finishLine(self: *Editor) !void {
        self.cursor = self.buffer.items.len;
        try self.draw(false);
    }

    fn redraw(self: *Editor) !void {
        try self.refreshGhost();
        try self.draw(true);
    }

    fn draw(self: *Editor, ghost: bool) !void {
        const cols = terminalColumns();
        const hint: []const u8 = if (ghost) self.ghost_text.items else "";
        var buf: [4096]u8 = undefined;
        var fw = sys.stdout().writerStreaming(sys.io, &buf);
        const w = &fw.interface;

        if (self.cursor_row > 0) try w.print("\x1b[{d}A", .{self.cursor_row});
        try w.writeAll("\r\x1b[J");
        if (self.marks) try w.writeAll("\x1b]133;A\x07");
        try w.writeAll(self.prompt);
        if (self.marks) try w.writeAll("\x1b]133;B\x07");
        try highlight.render(w, self.buffer.items);
        if (hint.len > 0) try w.print("\x1b[38;5;240m{s}\x1b[0m", .{hint});

        var end = Position{};
        advance(&end, self.prompt, cols);
        advance(&end, self.buffer.items, cols);
        advance(&end, hint, cols);
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
        try w.flush();
    }
};

fn readByte() !u8 {
    var byte: [1]u8 = undefined;
    const n = try sys.read(sys.STDIN_FILENO, &byte);
    if (n == 0) return error.EndOfStream;
    return byte[0];
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
        if (text[i] == '\n') {
            pos.* = .{ .row = pos.row + 1 };
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

fn terminalColumns() usize {
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) != .SUCCESS or ws.col < 2) return 80;
    return ws.col;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn wordLeft(items: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and !isWordByte(items[i - 1])) i -= 1;
    while (i > 0 and isWordByte(items[i - 1])) i -= 1;
    return i;
}

fn wordRight(items: []const u8, pos: usize) usize {
    var i = pos;
    while (i < items.len and !isWordByte(items[i])) i += 1;
    while (i < items.len and isWordByte(items[i])) i += 1;
    return i;
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
