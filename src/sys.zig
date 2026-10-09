const std = @import("std");
const c = std.c;
const posix = std.posix;

/// Process-wide I/O implementation, set once by main from `std.process.Init`.
pub var io: std.Io = undefined;

pub const fd_t = posix.fd_t;
pub const pid_t = posix.pid_t;
pub const STDIN_FILENO = posix.STDIN_FILENO;
pub const STDOUT_FILENO = posix.STDOUT_FILENO;
pub const STDERR_FILENO = posix.STDERR_FILENO;

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub fn stdout() std.Io.File {
    return std.Io.File.stdout();
}

pub fn stderr() std.Io.File {
    return std.Io.File.stderr();
}

pub fn isTty(file: std.Io.File) bool {
    return file.isTty(io) catch false;
}

/// Unbuffered write of all bytes. Streaming (not positional) so it respects
/// O_APPEND and the current offset of redirected descriptors.
pub fn writeAll(file: std.Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(io, bytes);
}

pub fn print(file: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    fw.interface.print(fmt, args) catch return fw.err orelse error.WriteFailed;
    fw.interface.flush() catch return fw.err orelse error.WriteFailed;
}

pub const ReadError = posix.ReadError;

pub fn read(fd: fd_t, buf: []u8) ReadError!usize {
    return posix.read(fd, buf);
}

pub const ForkError = error{ SystemResources, Unexpected };

pub fn fork() ForkError!pid_t {
    const rc = c.fork();
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN, .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub const PipeError = error{ ProcessFdQuotaExceeded, SystemFdQuotaExceeded, Unexpected };

pub fn pipe() PipeError![2]fd_t {
    var fds: [2]fd_t = undefined;
    return switch (posix.errno(c.pipe(&fds))) {
        .SUCCESS => fds,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn close(fd: fd_t) void {
    _ = c.close(fd);
}

pub const DupError = error{ ProcessFdQuotaExceeded, BadFileDescriptor, Unexpected };

pub fn dup(fd: fd_t) DupError!fd_t {
    const rc = c.dup(fd);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE => error.ProcessFdQuotaExceeded,
        .BADF => error.BadFileDescriptor,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn dup2(old_fd: fd_t, new_fd: fd_t) DupError!void {
    while (true) {
        switch (posix.errno(c.dup2(old_fd, new_fd))) {
            .SUCCESS => return,
            .INTR, .BUSY => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .BADF => return error.BadFileDescriptor,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Terminates immediately without running atexit handlers or flushing libc
/// buffers, which is what a forked child must do.
pub fn exit(status: u8) noreturn {
    c._exit(status);
}

pub const PathError = error{
    FileNotFound,
    NotDir,
    AccessDenied,
    NameTooLong,
    SymLinkLoop,
    IsDir,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    FileBusy,
    Unexpected,
};

fn pathError(err: posix.E) PathError {
    return switch (err) {
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ACCES, .PERM => error.AccessDenied,
        .NAMETOOLONG => error.NameTooLong,
        .LOOP => error.SymLinkLoop,
        .ISDIR => error.IsDir,
        .NOSPC => error.NoSpaceLeft,
        .ROFS => error.ReadOnlyFileSystem,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .TXTBSY => error.FileBusy,
        else => posix.unexpectedErrno(err),
    };
}

pub fn chdir(path: []const u8) PathError!void {
    const path_z = try posix.toPosixPath(path);
    return switch (posix.errno(c.chdir(&path_z))) {
        .SUCCESS => {},
        else => |err| pathError(err),
    };
}

pub fn access(path: []const u8, mode: u32) PathError!void {
    const path_z = try posix.toPosixPath(path);
    return switch (posix.errno(c.access(&path_z, mode))) {
        .SUCCESS => {},
        else => |err| pathError(err),
    };
}

pub fn open(path: []const u8, flags: posix.O, mode: posix.mode_t) PathError!fd_t {
    const path_z = try posix.toPosixPath(path);
    while (true) {
        const rc = c.open(&path_z, flags, mode);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return pathError(err),
        }
    }
}

pub fn lseekSet(fd: fd_t, offset: u64) void {
    _ = c.lseek(fd, @intCast(offset), c.SEEK.SET);
}

pub fn getCwd(buf: []u8) error{ CurrentDirUnlinked, NameTooLong, Unexpected }![]u8 {
    if (c.getcwd(buf.ptr, buf.len) != null) return std.mem.sliceTo(buf, 0);
    return switch (posix.errno(@as(c_int, -1))) {
        .NOENT => error.CurrentDirUnlinked,
        .RANGE => error.NameTooLong,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub const ExecveError = PathError || error{ InvalidExe, FileSystem };

/// Only returns on failure.
pub fn execve(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecveError {
    return switch (posix.errno(c.execve(path, argv, envp))) {
        .SUCCESS => unreachable,
        .NOEXEC => error.InvalidExe,
        .IO => error.FileSystem,
        .@"2BIG" => error.SystemResources,
        else => |err| pathError(err),
    };
}

pub fn waitpid(pid: pid_t) u32 {
    var status: c_int = 0;
    while (true) {
        switch (posix.errno(c.waitpid(pid, &status, 0))) {
            .SUCCESS => return @bitCast(status),
            .INTR => continue,
            else => return 0,
        }
    }
}

pub fn timestamp() i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}
