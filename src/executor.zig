const std = @import("std");
const posix = std.posix;
const parser = @import("parser.zig");

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

    pub fn run(self: *Shell, arena: std.mem.Allocator, pipelines: []const parser.Pipeline) !?u8 {
        for (pipelines) |pipeline| {
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
            if (self.builtin(cmds[0].argv)) |outcome| return outcome;
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
            if (pid == 0) self.child(arena, cmd.argv, input, output);

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

    fn child(self: *Shell, arena: std.mem.Allocator, argv: []const []const u8, input: ?posix.fd_t, output: ?[2]posix.fd_t) noreturn {
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
        if (self.builtin(argv)) |outcome| {
            switch (outcome) {
                .status => |status| posix.exit(status),
                .exit => |code| posix.exit(code),
            }
        }
        execute(arena, argv);
    }

    fn builtin(self: *Shell, argv: []const []const u8) ?Outcome {
        const name = argv[0];
        if (std.mem.eql(u8, name, "cd")) return .{ .status = changeDirectory(argv[1..]) };
        if (std.mem.eql(u8, name, "exit")) return exitShell(self.last_status, argv[1..]);
        return null;
    }
};

fn changeDirectory(args: []const []const u8) u8 {
    if (args.len > 1) {
        printError("cd: too many arguments", .{});
        return 1;
    }
    var target: []const u8 = undefined;
    if (args.len == 1) {
        target = args[0];
    } else {
        target = posix.getenv("HOME") orelse {
            printError("cd: HOME is not set", .{});
            return 1;
        };
    }
    posix.chdir(target) catch |err| {
        printError("cd: {s}: {s}", .{ target, describe(err) });
        return 1;
    };
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

fn execute(arena: std.mem.Allocator, argv: []const []const u8) noreturn {
    const argv_z = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch posix.exit(1);
    for (argv, 0..) |arg, i| {
        argv_z[i] = (arena.dupeZ(u8, arg) catch posix.exit(1)).ptr;
    }
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);
    const err = posix.execvpeZ(argv_z[0].?, argv_z.ptr, envp);
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
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        else => @errorName(err),
    };
}

fn printError(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print("zs: " ++ fmt ++ "\n", args) catch {};
}
