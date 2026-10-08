const std = @import("std");
const posix = std.posix;
const parser = @import("parser.zig");
const vars = @import("vars.zig");
const commands = @import("commands.zig");

pub const Outcome = union(enum) {
    status: u8,
    exit: u8,
};

pub fn ignoreInteractiveSignals() void {
    const ignore = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &ignore, null);
    posix.sigaction(posix.SIG.TSTP, &ignore, null);
}

fn restoreDefaultSignals() void {
    const default = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &default, null);
}

pub const Shell = struct {
    last_status: u8 = 0,

    pub fn run(self: *Shell, arena: std.mem.Allocator, line: []const u8, lines: ?parser.LineSource) anyerror!?u8 {
        var p = parser.Parser.init(arena, line);
        p.lines = lines;
        while (try p.next(self.last_status)) |pipeline| {
            const should_run = switch (pipeline.join) {
                .always => true,
                .and_if => self.last_status == 0,
                .or_if => self.last_status != 0,
            };
            if (!should_run) continue;
            switch (try self.runPipeline(arena, pipeline)) {
                .status => |status| self.last_status = status,
                .exit => |code| return code,
            }
        }
        return null;
    }

    fn runPipeline(self: *Shell, arena: std.mem.Allocator, pipeline: parser.Pipeline) !Outcome {
        const cmds = pipeline.commands;
        if (cmds.len == 1) {
            const cmd = cmds[0];
            if (cmd.argv.len == 0 or isBuiltin(cmd.argv[0])) {
                const saved = saveStandardFds();
                defer restoreStandardFds(saved);
                if (!applyRedirects(cmd.redirects)) return .{ .status = 1 };
                if (cmd.argv.len == 0) return .{ .status = assign(cmd.assignments) };
                return self.builtin(arena, cmd.argv).?;
            }
        }

        const pids = try arena.alloc(posix.pid_t, cmds.len);
        var input: ?posix.fd_t = null;
        var spawned: usize = 0;
        for (cmds, 0..) |cmd, i| {
            const output: ?[2]posix.fd_t = if (i + 1 == cmds.len) null else try posix.pipe();
            const pid = posix.fork() catch |err| {
                if (input) |fd| posix.close(fd);
                if (output) |fds| {
                    posix.close(fds[0]);
                    posix.close(fds[1]);
                }
                var interrupted = false;
                for (pids[0..spawned]) |spawned_pid| _ = reap(spawned_pid, &interrupted);
                return err;
            };
            if (pid == 0) self.child(arena, cmd, input, output);

            pids[i] = pid;
            spawned += 1;
            if (input) |fd| posix.close(fd);
            if (output) |fds| {
                posix.close(fds[1]);
                input = fds[0];
            } else {
                input = null;
            }
        }

        var status: u8 = 0;
        var interrupted = false;
        for (pids) |pid| status = reap(pid, &interrupted);
        if (interrupted) std.io.getStdOut().writeAll("\n") catch {};
        return .{ .status = status };
    }

    fn child(self: *Shell, arena: std.mem.Allocator, cmd: parser.Command, input: ?posix.fd_t, output: ?[2]posix.fd_t) noreturn {
        restoreDefaultSignals();
        if (input) |fd| {
            posix.dup2(fd, posix.STDIN_FILENO) catch posix.exit(126);
            posix.close(fd);
        }
        if (output) |fds| {
            posix.dup2(fds[1], posix.STDOUT_FILENO) catch posix.exit(126);
            posix.close(fds[0]);
            posix.close(fds[1]);
        }
        if (!applyRedirects(cmd.redirects)) posix.exit(1);
        if (cmd.argv.len == 0) posix.exit(assign(cmd.assignments));
        if (self.builtin(arena, cmd.argv)) |outcome| {
            switch (outcome) {
                .status => |status| posix.exit(status),
                .exit => |code| posix.exit(code),
            }
        }
        execute(arena, cmd);
    }

    fn builtin(self: *Shell, arena: std.mem.Allocator, argv: []const []const u8) ?Outcome {
        const name = argv[0];
        if (std.mem.eql(u8, name, "cd")) return .{ .status = changeDirectory(argv[1..]) };
        if (std.mem.eql(u8, name, "exit")) return exitShell(self.last_status, argv[1..]);
        if (std.mem.eql(u8, name, "export")) return .{ .status = exportVariables(arena, argv[1..]) };
        if (std.mem.eql(u8, name, "unset")) return .{ .status = unsetVariables(argv[1..]) };
        return null;
    }
};

fn isBuiltin(name: []const u8) bool {
    for (commands.builtins) |builtin_name| {
        if (std.mem.eql(u8, builtin_name, name)) return true;
    }
    return false;
}

fn saveStandardFds() [3]?posix.fd_t {
    var saved: [3]?posix.fd_t = .{ null, null, null };
    for (&saved, 0..) |*slot, fd| slot.* = posix.dup(@intCast(fd)) catch null;
    return saved;
}

fn restoreStandardFds(saved: [3]?posix.fd_t) void {
    for (saved, 0..) |maybe, fd| {
        const copy = maybe orelse continue;
        posix.dup2(copy, @intCast(fd)) catch {};
        posix.close(copy);
    }
}

fn applyRedirects(redirects: []const parser.Redirect) bool {
    for (redirects) |redirect| {
        const fd: posix.fd_t = redirect.fd;
        if (redirect.kind == .heredoc) {
            const memory = posix.memfd_create("zs-heredoc", 0) catch {
                printError("cannot create here-document", .{});
                return false;
            };
            const file = std.fs.File{ .handle = memory };
            file.writeAll(redirect.target) catch {
                posix.close(memory);
                printError("cannot write here-document", .{});
                return false;
            };
            posix.lseek_SET(memory, 0) catch {};
            if (memory != fd) {
                posix.dup2(memory, fd) catch {
                    posix.close(memory);
                    printError("{d}: Bad file descriptor", .{fd});
                    return false;
                };
                posix.close(memory);
            }
            continue;
        }
        if (redirect.kind == .dup) {
            if (std.mem.eql(u8, redirect.target, "-")) {
                posix.close(fd);
                continue;
            }
            const source = std.fmt.parseInt(posix.fd_t, redirect.target, 10) catch {
                printError("{s}: ambiguous redirect", .{redirect.target});
                return false;
            };
            posix.dup2(source, fd) catch {
                printError("{d}: Bad file descriptor", .{source});
                return false;
            };
            continue;
        }
        const flags: posix.O = switch (redirect.kind) {
            .read => .{ .ACCMODE = .RDONLY },
            .write => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            .append => .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            .dup, .heredoc => unreachable,
        };
        const opened = posix.open(redirect.target, flags, 0o666) catch |err| {
            printError("{s}: {s}", .{ redirect.target, describe(err) });
            return false;
        };
        if (opened != fd) {
            posix.dup2(opened, fd) catch {
                posix.close(opened);
                printError("{d}: Bad file descriptor", .{fd});
                return false;
            };
            posix.close(opened);
        }
    }
    return true;
}

fn assign(assignments: []const vars.Assignment) u8 {
    for (assignments) |assignment| {
        vars.set(assignment.name, assignment.value) catch {
            printError("out of memory", .{});
            return 1;
        };
    }
    return 0;
}

fn exportVariables(arena: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len == 0) {
        const names = vars.exportedNames(arena) catch return 1;
        const stdout = std.io.getStdOut().writer();
        for (names) |name| {
            stdout.print("export {s}=\"{s}\"\n", .{ name, vars.get(name) orelse "" }) catch return 1;
        }
        return 0;
    }
    var status: u8 = 0;
    for (args) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (eq) |i| arg[0..i] else arg;
        if (!parser.isName(name)) {
            printError("export: '{s}': not a valid identifier", .{arg});
            status = 1;
            continue;
        }
        if (eq) |i| vars.set(name, arg[i + 1 ..]) catch {
            printError("out of memory", .{});
            return 1;
        };
        vars.markExported(name) catch {
            printError("out of memory", .{});
            return 1;
        };
    }
    return status;
}

fn unsetVariables(args: []const []const u8) u8 {
    var status: u8 = 0;
    for (args) |name| {
        if (!parser.isName(name)) {
            printError("unset: '{s}': not a valid identifier", .{name});
            status = 1;
            continue;
        }
        vars.unset(name);
    }
    return status;
}

fn changeDirectory(args: []const []const u8) u8 {
    if (args.len > 1) {
        printError("cd: too many arguments", .{});
        return 1;
    }
    var target: []const u8 = undefined;
    var announce = false;
    if (args.len == 1 and std.mem.eql(u8, args[0], "-")) {
        target = vars.get("OLDPWD") orelse {
            printError("cd: OLDPWD is not set", .{});
            return 1;
        };
        announce = true;
    } else if (args.len == 1) {
        target = args[0];
    } else {
        target = vars.get("HOME") orelse {
            printError("cd: HOME is not set", .{});
            return 1;
        };
    }

    var old_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old: ?[]u8 = std.process.getCwd(&old_buf) catch null;
    posix.chdir(target) catch |err| {
        printError("cd: {s}: {s}", .{ target, describe(err) });
        return 1;
    };

    var new_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.process.getCwd(&new_buf)) |new| {
        if (old) |previous| {
            vars.set("OLDPWD", previous) catch {};
            vars.markExported("OLDPWD") catch {};
        }
        vars.set("PWD", new) catch {};
        vars.markExported("PWD") catch {};
        if (announce) std.io.getStdOut().writer().print("{s}\n", .{new}) catch {};
    } else |_| {}
    return 0;
}

fn exitShell(last_status: u8, args: []const []const u8) Outcome {
    if (args.len == 0) return .{ .exit = last_status };
    const code = std.fmt.parseInt(i64, args[0], 10) catch {
        printError("exit: {s}: numeric argument required", .{args[0]});
        return .{ .exit = 2 };
    };
    return .{ .exit = @intCast(@mod(code, 256)) };
}

fn execute(arena: std.mem.Allocator, cmd: parser.Command) noreturn {
    const argv = cmd.argv;
    const argv_z = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch posix.exit(1);
    for (argv, 0..) |arg, i| {
        argv_z[i] = (arena.dupeZ(u8, arg) catch posix.exit(1)).ptr;
    }
    const envp = vars.environ(arena, cmd.assignments) catch posix.exit(1);
    const err = searchAndExec(arena, argv[0], cmd.assignments, argv_z.ptr, envp.ptr);
    switch (err) {
        error.FileNotFound => {
            if (std.mem.indexOfScalar(u8, argv[0], '/') != null) {
                printError("{s}: No such file or directory", .{argv[0]});
            } else {
                printError("{s}: command not found", .{argv[0]});
            }
            posix.exit(127);
        },
        else => {
            printError("{s}: {s}", .{ argv[0], describe(err) });
            posix.exit(126);
        },
    }
}

fn searchAndExec(
    arena: std.mem.Allocator,
    name: []const u8,
    assignments: []const vars.Assignment,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) posix.ExecveError {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return posix.execveZ(argv[0].?, argv, envp);

    var path: []const u8 = vars.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    for (assignments) |assignment| {
        if (std.mem.eql(u8, assignment.name, "PATH")) path = assignment.value;
    }
    var denied = false;
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        const candidate = std.fmt.allocPrintZ(arena, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch return error.SystemResources;
        switch (posix.execveZ(candidate, argv, envp)) {
            error.FileNotFound, error.NotDir => {},
            error.AccessDenied => denied = true,
            else => |err| return err,
        }
    }
    return if (denied) error.AccessDenied else error.FileNotFound;
}

fn reap(pid: posix.pid_t, interrupted: *bool) u8 {
    const status = posix.waitpid(pid, 0).status;
    if (posix.W.IFEXITED(status)) return posix.W.EXITSTATUS(status);
    if (posix.W.IFSIGNALED(status)) {
        const sig = posix.W.TERMSIG(status);
        if (sig == posix.SIG.INT) interrupted.* = true;
        return @intCast(128 + sig);
    }
    return 1;
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.NotDir => "Not a directory",
        error.AccessDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        else => @errorName(err),
    };
}

fn printError(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print("zs: " ++ fmt ++ "\n", args) catch {};
}
