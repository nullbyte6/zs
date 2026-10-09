const std = @import("std");
const sys = @import("sys.zig");
const vars = @import("vars.zig");

pub const Option = struct {
    text: []const u8,
    hint: []const u8 = "",
};

const Curated = struct {
    command: []const u8,
    subcommands: []const []const u8,
};

const apt_subcommands: []const []const u8 = &.{ "autoclean", "autoremove", "full-upgrade", "install", "list", "policy", "purge", "reinstall", "remove", "search", "show", "update", "upgrade" };

const curated = [_]Curated{
    .{ .command = "apt", .subcommands = apt_subcommands },
    .{ .command = "apt-get", .subcommands = apt_subcommands },
    .{ .command = "cargo", .subcommands = &.{ "add", "bench", "build", "check", "clean", "clippy", "doc", "fmt", "init", "install", "new", "publish", "remove", "run", "test", "update" } },
    .{ .command = "docker", .subcommands = &.{ "build", "compose", "cp", "exec", "images", "inspect", "login", "logs", "network", "ps", "pull", "push", "restart", "rm", "rmi", "run", "start", "stop", "tag", "volume" } },
    .{ .command = "npm", .subcommands = &.{ "ci", "init", "install", "publish", "run", "start", "test", "uninstall", "update" } },
    .{ .command = "systemctl", .subcommands = &.{ "cat", "daemon-reload", "disable", "edit", "enable", "is-active", "is-enabled", "kill", "list-unit-files", "list-units", "mask", "reload", "reset-failed", "restart", "show", "start", "status", "stop", "unmask" } },
    .{ .command = "zig", .subcommands = &.{ "ast-check", "build", "build-exe", "build-lib", "build-obj", "env", "fetch", "fmt", "init", "run", "test", "translate-c", "version" } },
};

const man_roots = [_][]const u8{ "/usr/share/man", "/usr/local/share/man" };
const man_sections = [_][]const u8{ "1", "8" };
const max_page = 4 * 1024 * 1024;
const min_discovered = 3;

var allocator: std.mem.Allocator = undefined;
var names_arena: std.heap.ArenaAllocator = undefined;
var names: []const []const u8 = &.{};
var names_path: []const u8 = "";
var names_ready = false;
var specs_arena: std.heap.ArenaAllocator = undefined;
var subs_cache: std.StringHashMapUnmanaged([]const []const u8) = .{};
var options_cache: std.StringHashMapUnmanaged([]const Option) = .{};

pub fn init(gpa: std.mem.Allocator) void {
    allocator = gpa;
    names_arena = .init(gpa);
    specs_arena = .init(gpa);
}

pub fn deinit() void {
    subs_cache.deinit(allocator);
    options_cache.deinit(allocator);
    names_arena.deinit();
    specs_arena.deinit();
}

pub fn invalidate() void {
    names_ready = false;
}

pub fn commandNames() []const []const u8 {
    const path = vars.get("PATH") orelse "";
    if (names_ready and std.mem.eql(u8, path, names_path)) return names;
    _ = names_arena.reset(.free_all);
    const arena = names_arena.allocator();
    names = scanPath(arena, path) catch &.{};
    names_path = arena.dupe(u8, path) catch "";
    names_ready = true;
    return names;
}

fn scanPath(arena: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir_path| {
        var dir = sys.cwd().openDir(sys.io, if (dir_path.len == 0) "." else dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(sys.io);
        var it = dir.iterate();
        while (it.next(sys.io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            try list.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    return uniqueSorted([]const u8, list.items, {}, lessName, eqlName);
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn eqlName(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn uniqueSorted(comptime T: type, items: []T, context: void, comptime less: fn (void, T, T) bool, comptime same: fn (T, T) bool) []T {
    std.mem.sort(T, items, context, less);
    var unique: usize = 0;
    for (items) |item| {
        if (unique > 0 and same(items[unique - 1], item)) continue;
        items[unique] = item;
        unique += 1;
    }
    return items[0..unique];
}

fn compareName(key: []const u8, item: []const u8) std.math.Order {
    return std.mem.order(u8, key, item);
}

fn hasCommand(name: []const u8) bool {
    return std.sort.binarySearch([]const u8, commandNames(), name, compareName) != null;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.' or name[0] == '-') return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '+' and c != '.') return false;
    }
    return true;
}

const popular_git = [_][]const u8{ "status", "add", "commit", "push", "pull", "checkout", "branch", "log", "diff", "merge", "rebase", "stash", "fetch", "clone", "reset", "restore", "switch", "show", "tag", "remote", "init" };

pub fn popularity(command: []const u8, sub: []const u8) u8 {
    if (!std.mem.eql(u8, command, "git")) return std.math.maxInt(u8);
    for (popular_git, 0..) |name, rank| {
        if (std.mem.eql(u8, name, sub)) return @intCast(rank);
    }
    return std.math.maxInt(u8);
}

pub fn subcommands(command: []const u8) []const []const u8 {
    if (!validName(command)) return &.{};
    if (subs_cache.get(command)) |cached| return cached;
    const arena = specs_arena.allocator();
    const key = arena.dupe(u8, command) catch return &.{};
    const found = discoverSubcommands(arena, command) catch &.{};
    subs_cache.put(allocator, key, found) catch {};
    return found;
}

fn discoverSubcommands(arena: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    for (curated) |entry| {
        if (std.mem.eql(u8, entry.command, command)) return entry.subcommands;
    }
    const prefix = try std.fmt.allocPrint(arena, "{s}-", .{command});
    var list: std.ArrayList([]const u8) = .empty;
    for (man_roots) |root| for (man_sections) |section| {
        const dir_path = try std.fmt.allocPrint(arena, "{s}/man{s}", .{ root, section });
        var dir = sys.cwd().openDir(sys.io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(sys.io);
        var it = dir.iterate();
        while (it.next(sys.io) catch null) |entry| {
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            const page = pageName(entry.name);
            if (page.len <= prefix.len or hasCommand(page)) continue;
            try list.append(arena, try arena.dupe(u8, page[prefix.len..]));
        }
    };
    const found = uniqueSorted([]const u8, list.items, {}, lessName, eqlName);
    return if (found.len >= min_discovered) found else &.{};
}

fn pageName(file: []const u8) []const u8 {
    var name = file;
    if (std.mem.endsWith(u8, name, ".gz")) name = name[0 .. name.len - 3];
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

pub fn options(command: []const u8, sub: []const u8) []const Option {
    if (!validName(command)) return &.{};
    const use_sub = sub.len > 0 and validName(sub);
    const arena = specs_arena.allocator();
    const key = if (use_sub) std.fmt.allocPrint(arena, "{s} {s}", .{ command, sub }) catch return &.{} else command;
    if (options_cache.get(key)) |cached| return cached;
    const stored = arena.dupe(u8, key) catch return &.{};
    const found = loadOptions(arena, command, if (use_sub) sub else "") catch &.{};
    options_cache.put(allocator, stored, found) catch {};
    return found;
}

pub fn find(command: []const u8, sub: []const u8, text: []const u8) ?Option {
    for (options(command, sub)) |option| {
        if (std.mem.eql(u8, option.text, text)) return option;
    }
    return null;
}

fn loadOptions(arena: std.mem.Allocator, command: []const u8, sub: []const u8) ![]const Option {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    if (sub.len > 0) {
        const page = try std.fmt.allocPrint(scratch.allocator(), "{s}-{s}", .{ command, sub });
        if (readPage(scratch.allocator(), page)) |text| return parseOptions(arena, text);
    }
    if (readPage(scratch.allocator(), command)) |text| return parseOptions(arena, text);
    return &.{};
}

fn readPage(scratch: std.mem.Allocator, page: []const u8) ?[]const u8 {
    for (man_roots) |root| {
        var dir = std.Io.Dir.openDirAbsolute(sys.io, root, .{}) catch continue;
        defer dir.close(sys.io);
        for (man_sections) |section| for ([_][]const u8{ ".gz", "" }) |extension| {
            const path = std.fmt.allocPrint(scratch, "man{s}/{s}.{s}{s}", .{ section, page, section, extension }) catch return null;
            var text = loadFile(scratch, dir, path) orelse continue;
            if (std.mem.startsWith(u8, text, ".so ")) {
                const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
                const target = std.mem.trim(u8, text[4..end], " \t\r");
                text = loadTarget(scratch, dir, target) orelse continue;
            }
            return text;
        };
    }
    return null;
}

fn loadTarget(scratch: std.mem.Allocator, dir: std.Io.Dir, target: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, target, "..") != null or target.len == 0 or target[0] == '/') return null;
    if (loadFile(scratch, dir, target)) |text| return text;
    const zipped = std.fmt.allocPrint(scratch, "{s}.gz", .{target}) catch return null;
    return loadFile(scratch, dir, zipped);
}

fn loadFile(scratch: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ?[]const u8 {
    const raw = dir.readFileAlloc(sys.io, path, scratch, .limited(max_page)) catch return null;
    if (!std.mem.endsWith(u8, path, ".gz")) return raw;
    var input: std.Io.Reader = .fixed(raw);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    return gzip.reader.allocRemaining(scratch, .unlimited) catch null;
}

fn parseOptions(arena: std.mem.Allocator, text: []const u8) ![]const Option {
    var list: std.ArrayList(Option) = .empty;
    var cursor: usize = 0;
    var chain: usize = 0;
    var previous_end: usize = 0;
    while (std.mem.indexOfPos(u8, text, cursor, "\\fB")) |marker| {
        const start = marker + 3;
        const end = fontEnd(text, start) orelse break;
        cursor = end + 3;
        var buf: [64]u8 = undefined;
        const name = optionName(&buf, text[start..end]) orelse continue;
        var option_text = name;
        const rest = text[cursor..];
        var hint: []const u8 = "";
        var offset: usize = 0;
        if (std.mem.startsWith(u8, rest, "[=")) {
            offset = 2;
        } else if (std.mem.startsWith(u8, rest, "=")) {
            offset = 1;
            if (name[name.len - 1] != '=') option_text = try std.fmt.allocPrint(arena, "{s}=", .{name});
        } else if (std.mem.startsWith(u8, rest, " ")) {
            offset = 1;
        }
        if (std.mem.startsWith(u8, rest[offset..], "\\fI")) {
            const hint_start = offset + 3;
            if (fontEnd(rest, hint_start)) |hint_end| hint = cleanHint(rest[hint_start..hint_end]);
        }

        const joined = list.items.len > 0 and marker >= previous_end and std.mem.eql(u8, text[previous_end..marker], ", ");
        if (!joined) chain = list.items.len;
        previous_end = cursor;
        try list.append(arena, .{ .text = try arena.dupe(u8, option_text), .hint = try arena.dupe(u8, hint) });
        if (hint.len > 0) {
            for (list.items[chain..]) |*earlier| {
                if (earlier.hint.len == 0 and earlier.text[earlier.text.len - 1] != '=') earlier.hint = list.items[list.items.len - 1].hint;
            }
        }
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!isOptionMacro(line)) continue;
        var tokens = std.mem.tokenizeAny(u8, line, " \t\",");
        _ = tokens.next();
        while (tokens.next()) |token| {
            var buf: [64]u8 = undefined;
            const name = optionName(&buf, token) orelse continue;
            try list.append(arena, .{ .text = try arena.dupe(u8, name) });
        }
    }

    std.mem.sort(Option, list.items, {}, lessOption);
    var unique: usize = 0;
    for (list.items) |option| {
        if (unique > 0 and std.mem.eql(u8, list.items[unique - 1].text, option.text)) {
            if (list.items[unique - 1].hint.len == 0) list.items[unique - 1].hint = option.hint;
            continue;
        }
        list.items[unique] = option;
        unique += 1;
    }
    return list.items[0..unique];
}

fn isOptionMacro(line: []const u8) bool {
    const macros = [_][]const u8{ ".B ", ".BR ", ".BI ", ".IP ", ".TP " };
    for (macros) |macro| {
        if (std.mem.startsWith(u8, line, macro)) return true;
    }
    return false;
}

fn fontEnd(text: []const u8, from: usize) ?usize {
    const roman = std.mem.indexOfPos(u8, text, from, "\\fR");
    const previous = std.mem.indexOfPos(u8, text, from, "\\fP");
    if (roman) |r| {
        if (previous) |p| return @min(r, p);
        return r;
    }
    return previous;
}

fn optionName(buf: []u8, raw: []const u8) ?[]const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var c = raw[i];
        if (c == '\\') {
            if (i + 1 >= raw.len) return null;
            i += 1;
            c = raw[i];
            if (c == '&') continue;
            if (c != '-') return null;
        }
        if (c == ' ') break;
        if (len >= buf.len) return null;
        buf[len] = c;
        len += 1;
    }
    const name = buf[0..len];
    if (name.len < 2 or name[0] != '-') return null;
    var dashes: usize = 0;
    while (dashes < name.len and name[dashes] == '-') dashes += 1;
    if (dashes > 2 or dashes == name.len) return null;
    for (name[dashes..], dashes..) |c, index| {
        const last = index == name.len - 1;
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '-' or c == '.') continue;
        if (c == '=' and last) continue;
        return null;
    }
    return name;
}

fn cleanHint(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " ");
    if (trimmed.len == 0 or trimmed.len > 24) return "";
    for (trimmed) |c| {
        if (c == '\\' or c == '\n') return "";
    }
    return trimmed;
}

fn lessOption(_: void, a: Option, b: Option) bool {
    return std.mem.lessThan(u8, a.text, b.text);
}
