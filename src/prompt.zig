const std = @import("std");
const posix = std.posix;
const vars = @import("vars.zig");
const sys = @import("sys.zig");

pub const default_format = "\\e[1;32m\\u@\\h\\e[0m \\e[1;34m\\W\\e[0m\\e[1;33m>>\\e[0m ";

pub const help =
    \\zsprompt [FORMAT | --reset | --help]
    \\
    \\  \u user        \h host        \H full host
    \\  \w directory with ~            \W directory name
    \\  \t HH:MM:SS     \A HH:MM       \d date
    \\  \g git branch  \? last status \$ # for root, $ otherwise
    \\  \n newline     \e or \033 escape  \\ backslash
    \\  \[ \] ignored (accepted for bash compatibility)
    \\
    \\The format is also expanded for $VAR and $(command) each time the prompt is drawn.
    \\
;

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timer: *const c_long, result: *Tm) ?*Tm;

const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const known_escapes = "uhHwWtAdg?$ne\\[]";

var allocator: std.mem.Allocator = undefined;
var custom: ?[]u8 = null;

pub fn init(gpa: std.mem.Allocator) void {
    allocator = gpa;
}

pub fn deinit() void {
    if (custom) |text| allocator.free(text);
    custom = null;
}

pub fn format() []const u8 {
    return custom orelse default_format;
}

pub fn setFormat(text: []const u8) !void {
    const copy = try allocator.dupe(u8, text);
    if (custom) |old| allocator.free(old);
    custom = copy;
}

pub fn reset() void {
    if (custom) |old| allocator.free(old);
    custom = null;
}

pub fn unknownEscapes(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var found: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] != '\\') continue;
        i += 1;
        if (std.mem.startsWith(u8, text[i..], "033")) {
            i += 2;
        } else if (std.mem.indexOfScalar(u8, known_escapes, text[i]) == null) {
            if (std.mem.indexOfScalar(u8, found.items, text[i]) == null) try found.append(arena, text[i]);
        }
    }
    return found.items;
}

pub fn render(arena: std.mem.Allocator, text: []const u8, color: bool, last_status: u8) ![]const u8 {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = sys.getCwd(&cwd_buf) catch "";
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\' or i + 1 >= text.len) {
            try out.append(arena, text[i]);
            continue;
        }
        i += 1;
        switch (text[i]) {
            'u' => try out.appendSlice(arena, vars.get("USER") orelse "user"),
            'h', 'H' => {
                var host_buf: [posix.HOST_NAME_MAX]u8 = undefined;
                const full = posix.gethostname(&host_buf) catch "localhost";
                try out.appendSlice(arena, if (text[i] == 'H') full else full[0 .. std.mem.indexOfScalar(u8, full, '.') orelse full.len]);
            },
            'w' => try out.appendSlice(arena, try homeRelative(arena, cwd)),
            'W' => try out.appendSlice(arena, directoryName(cwd)),
            't', 'A', 'd' => if (localNow()) |tm| try appendTime(arena, &out, tm, text[i]),
            'g' => if (gitBranch(arena, cwd)) |branch| try out.appendSlice(arena, branch),
            '?' => try out.print(arena, "{d}", .{last_status}),
            '$' => try out.append(arena, if (std.os.linux.geteuid() == 0) '#' else '$'),
            'n' => try out.append(arena, '\n'),
            'e' => try out.append(arena, 0x1b),
            '0' => {
                if (std.mem.startsWith(u8, text[i..], "033")) {
                    try out.append(arena, 0x1b);
                    i += 2;
                } else {
                    try out.appendSlice(arena, "\\0");
                }
            },
            '\\' => try out.append(arena, '\\'),
            '[', ']' => {},
            else => {
                try out.append(arena, '\\');
                try out.append(arena, text[i]);
            },
        }
    }
    if (!color) return stripEscapes(out.items);
    return out.items;
}

fn appendTime(arena: std.mem.Allocator, out: *std.ArrayList(u8), tm: Tm, kind: u8) !void {
    switch (kind) {
        't' => try out.print(arena, "{d:0>2}:{d:0>2}:{d:0>2}", .{ unsigned(tm.tm_hour), unsigned(tm.tm_min), unsigned(tm.tm_sec) }),
        'A' => try out.print(arena, "{d:0>2}:{d:0>2}", .{ unsigned(tm.tm_hour), unsigned(tm.tm_min) }),
        else => try out.print(arena, "{s} {s} {d:0>2}", .{
            weekdays[@intCast(@mod(tm.tm_wday, 7))],
            months[@intCast(@mod(tm.tm_mon, 12))],
            unsigned(tm.tm_mday),
        }),
    }
}

fn unsigned(value: c_int) u32 {
    return @intCast(@max(value, 0));
}

fn localNow() ?Tm {
    const seconds: c_long = @intCast(sys.timestamp());
    var tm: Tm = undefined;
    if (localtime_r(&seconds, &tm) == null) return null;
    return tm;
}

fn stripEscapes(text: []u8) []const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and (text[i] < 0x40 or text[i] > 0x7e)) i += 1;
            i += 1;
            continue;
        }
        text[len] = text[i];
        len += 1;
        i += 1;
    }
    return text[0..len];
}

fn gitBranch(arena: std.mem.Allocator, cwd: []const u8) ?[]const u8 {
    var dir: []const u8 = cwd;
    while (true) {
        if (headOf(arena, dir)) |branch| return branch;
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == dir.len) return null;
        dir = parent;
    }
}

fn headOf(arena: std.mem.Allocator, dir: []const u8) ?[]const u8 {
    const direct = std.fmt.allocPrint(arena, "{s}/.git/HEAD", .{dir}) catch return null;
    if (sys.cwd().readFileAlloc(sys.io, direct, arena, .limited(4096))) |content| return branchFrom(content) else |_| {}
    const pointer = std.fmt.allocPrint(arena, "{s}/.git", .{dir}) catch return null;
    const link = sys.cwd().readFileAlloc(sys.io, pointer, arena, .limited(4096)) catch return null;
    const trimmed = std.mem.trim(u8, link, " \r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir: ")) return null;
    const target = trimmed["gitdir: ".len..];
    const head = if (std.fs.path.isAbsolute(target))
        std.fmt.allocPrint(arena, "{s}/HEAD", .{target}) catch return null
    else
        std.fmt.allocPrint(arena, "{s}/{s}/HEAD", .{ dir, target }) catch return null;
    const content = sys.cwd().readFileAlloc(sys.io, head, arena, .limited(4096)) catch return null;
    return branchFrom(content);
}

fn branchFrom(content: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, content, " \r\n");
    if (std.mem.startsWith(u8, line, "ref: refs/heads/")) return line["ref: refs/heads/".len..];
    if (line.len >= 7) return line[0..7];
    return null;
}

fn homeRelative(arena: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const home = vars.get("HOME") orelse return cwd;
    if (home.len == 0 or !std.mem.startsWith(u8, cwd, home)) return cwd;
    if (cwd.len > home.len and cwd[home.len] != '/') return cwd;
    return std.fmt.allocPrint(arena, "~{s}", .{cwd[home.len..]});
}

fn directoryName(cwd: []const u8) []const u8 {
    if (vars.get("HOME")) |home| {
        if (home.len > 0 and std.mem.eql(u8, cwd, home)) return "~";
    }
    if (std.mem.eql(u8, cwd, "/")) return "/";
    return std.fs.path.basename(cwd);
}
