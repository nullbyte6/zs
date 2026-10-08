const std = @import("std");
const posix = std.posix;
const parser = @import("parser.zig");
const vars = @import("vars.zig");
const commands = @import("commands.zig");
const ast = @import("ast.zig");
const arith = @import("arith.zig");
const glob = @import("glob.zig");
const functions = @import("functions.zig");
const prompts = @import("prompt.zig");
const diag = @import("diag.zig");
const rc = @import("rc.zig");

pub const Outcome = union(enum) {
    status: u8,
    exit: u8,
    loop_break: u8,
    loop_continue: u8,
    fn_return: u8,
};

pub const Flow = union(enum) {
    normal,
    exit: u8,
    break_loop: u8,
    continue_loop: u8,
    return_fn: u8,
    interrupted,
};

const max_call_depth = 1000;

var sigint_seen = false;

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
    substitution_status: u8 = 0,
    call_depth: usize = 0,
    source_depth: usize = 0,
    errexit: bool = false,
    errexit_suspend: usize = 0,

    pub fn run(self: *Shell, arena: std.mem.Allocator, line: []const u8, lines: ?parser.LineSource) anyerror!?u8 {
        const flow = try self.runText(arena, line, lines);
        return switch (flow) {
            .exit => |code| code,
            .return_fn => |code| code,
            else => null,
        };
    }

    fn runText(self: *Shell, arena: std.mem.Allocator, line: []const u8, lines: ?parser.LineSource) anyerror!Flow {
        var text = line;
        const list = while (true) {
            const parsed = ast.parse(arena, text) catch |err| switch (err) {
                error.Incomplete => {
                    const source = lines orelse return error.UnexpectedEof;
                    const more = source.next(source.context, arena) orelse return error.UnexpectedEof;
                    text = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ text, more });
                    continue;
                },
                else => |other| return other,
            };
            break parsed;
        };
        if (list.len == 0) return .normal;
        if (!ast.hasCompound(list)) return self.execLine(arena, text, lines);
        return self.execList(arena, list, lines);
    }

    fn execList(self: *Shell, arena: std.mem.Allocator, list: ast.List, lines: ?parser.LineSource) anyerror!Flow {
        for (list, 0..) |item, index| {
            const should_run = switch (item.join) {
                .always => true,
                .and_if => self.last_status == 0,
                .or_if => self.last_status != 0,
            };
            if (!should_run) continue;
            const chained = index + 1 < list.len and list[index + 1].join != .always;
            if (chained) self.errexit_suspend += 1;
            const result = self.execNode(arena, item.node, lines);
            if (chained) self.errexit_suspend -= 1;
            const flow = try result;
            if (flow != .normal) return flow;
            if (self.errexit and self.errexit_suspend == 0 and !chained and self.last_status != 0) return .{ .exit = self.last_status };
        }
        return .normal;
    }

    fn execNode(self: *Shell, arena: std.mem.Allocator, node: ast.Node, lines: ?parser.LineSource) anyerror!Flow {
        switch (node) {
            .simple => |text| {
                var leaf = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer leaf.deinit();
                return self.execLine(leaf.allocator(), text, lines);
            },
            .arith => |text| {
                var p = parser.Parser.init(arena, text);
                p.last_status = self.last_status;
                p.substitute = .{ .context = self, .run = captureOutput, .status = &self.substitution_status };
                const expression = try p.expandBody(text);
                const value = arith.eval(expression) catch |err| {
                    printError("{s}", .{if (err == error.DivideByZero) "division by zero in arithmetic expression" else "syntax error in arithmetic expression"});
                    self.last_status = 1;
                    return .normal;
                };
                self.last_status = if (value != 0) 0 else 1;
                return .normal;
            },
            .redirected => |wrapped| {
                const redirect_command = try self.redirectCommand(arena, wrapped.redirs, lines);
                const saved = saveStandardFds();
                defer restoreStandardFds(saved);
                if (!applyRedirects(redirect_command.redirects)) {
                    self.last_status = 1;
                    return .normal;
                }
                return self.execNode(arena, wrapped.node.*, lines);
            },
            .pipeline => |stages| return self.execPipelineNodes(arena, stages, lines),
            .if_clause => |clause| {
                for (clause.branches) |branch| {
                    const cond_flow = try self.execCondition(arena, branch.cond, lines);
                    if (cond_flow != .normal) return cond_flow;
                    if (self.last_status == 0) return self.execList(arena, branch.body, lines);
                }
                if (clause.else_body) |body| return self.execList(arena, body, lines);
                self.last_status = 0;
                return .normal;
            },
            .loop => |loop| {
                var status: u8 = 0;
                while (true) {
                    const cond_flow = try self.execCondition(arena, loop.cond, lines);
                    if (cond_flow != .normal) return cond_flow;
                    if ((self.last_status == 0) == loop.until) break;
                    const body_flow = try self.execList(arena, loop.body, lines);
                    status = self.last_status;
                    switch (body_flow) {
                        .normal => {},
                        .break_loop => |levels| {
                            if (levels > 1) return .{ .break_loop = levels - 1 };
                            break;
                        },
                        .continue_loop => |levels| {
                            if (levels > 1) return .{ .continue_loop = levels - 1 };
                        },
                        else => return body_flow,
                    }
                }
                self.last_status = status;
                return .normal;
            },
            .group => |body| return self.execList(arena, body, lines),
            .subshell => |body| return self.execSubshell(arena, body, lines),
            .function => |definition| {
                functions.define(definition.name, definition.body) catch return error.OutOfMemory;
                self.last_status = 0;
                return .normal;
            },
            .case_clause => |clause| {
                const subject = try self.expandSingle(arena, clause.subject, .text, lines);
                for (clause.arms) |arm| {
                    for (arm.patterns) |pattern| {
                        const compiled = try self.expandSingle(arena, pattern, .pattern, lines);
                        if (!glob.match(compiled, subject)) continue;
                        self.last_status = 0;
                        return self.execList(arena, arm.body, lines);
                    }
                }
                self.last_status = 0;
                return .normal;
            },
            .for_clause => |clause| {
                const words = try self.expandWords(arena, clause.words, lines);
                var status: u8 = 0;
                for (words) |word| {
                    vars.set(clause.name, word) catch return error.OutOfMemory;
                    const body_flow = try self.execList(arena, clause.body, lines);
                    status = self.last_status;
                    switch (body_flow) {
                        .normal => {},
                        .break_loop => |levels| {
                            if (levels > 1) return .{ .break_loop = levels - 1 };
                            break;
                        },
                        .continue_loop => |levels| {
                            if (levels > 1) return .{ .continue_loop = levels - 1 };
                        },
                        else => return body_flow,
                    }
                }
                self.last_status = status;
                return .normal;
            },
        }
    }

    fn execCondition(self: *Shell, arena: std.mem.Allocator, list: ast.List, lines: ?parser.LineSource) anyerror!Flow {
        self.errexit_suspend += 1;
        defer self.errexit_suspend -= 1;
        return self.execList(arena, list, lines);
    }

    fn execSubshell(self: *Shell, arena: std.mem.Allocator, body: ast.List, lines: ?parser.LineSource) anyerror!Flow {
        const pid = try posix.fork();
        if (pid == 0) {
            restoreDefaultSignals();
            const flow = self.execList(arena, body, lines) catch posix.exit(1);
            posix.exit(switch (flow) {
                .exit => |code| code,
                .return_fn => |code| code,
                else => self.last_status,
            });
        }
        var interrupted = false;
        self.last_status = reap(pid, &interrupted);
        if (interrupted) {
            std.io.getStdOut().writeAll("\n") catch {};
            sigint_seen = false;
            return .interrupted;
        }
        return .normal;
    }

    fn redirectCommand(self: *Shell, arena: std.mem.Allocator, text: []const u8, lines: ?parser.LineSource) anyerror!parser.Command {
        var p = parser.Parser.init(arena, text);
        p.lines = lines;
        p.substitute = .{ .context = self, .run = captureOutput, .status = &self.substitution_status };
        const pipeline = (try p.next(self.last_status)) orelse return error.UnexpectedEof;
        return pipeline.commands[0];
    }

    fn execPipelineNodes(self: *Shell, arena: std.mem.Allocator, stages: []const ast.Node, lines: ?parser.LineSource) anyerror!Flow {
        const pids = try arena.alloc(posix.pid_t, stages.len);
        var input: ?posix.fd_t = null;
        var spawned: usize = 0;
        for (stages, 0..) |stage, i| {
            const output: ?[2]posix.fd_t = if (i + 1 == stages.len) null else try posix.pipe();
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
            if (pid == 0) {
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
                const flow = self.execNode(arena, stage, lines) catch posix.exit(1);
                posix.exit(switch (flow) {
                    .exit => |code| code,
                    .return_fn => |code| code,
                    else => self.last_status,
                });
            }
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
        self.last_status = status;
        if (interrupted) {
            std.io.getStdOut().writeAll("\n") catch {};
            sigint_seen = false;
            return .interrupted;
        }
        return .normal;
    }

    fn expandWords(self: *Shell, arena: std.mem.Allocator, text: []const u8, lines: ?parser.LineSource) anyerror![]const []const u8 {
        var p = parser.Parser.init(arena, text);
        p.lines = lines;
        p.substitute = .{ .context = self, .run = captureOutput, .status = &self.substitution_status };
        const pipeline = (try p.next(self.last_status)) orelse return &.{};
        return pipeline.commands[0].argv;
    }

    fn expandSingle(self: *Shell, arena: std.mem.Allocator, text: []const u8, mode: parser.Mode, lines: ?parser.LineSource) anyerror![]const u8 {
        var p = parser.Parser.init(arena, text);
        p.mode = mode;
        p.lines = lines;
        p.substitute = .{ .context = self, .run = captureOutput, .status = &self.substitution_status };
        const pipeline = (try p.next(self.last_status)) orelse return "";
        if (mode == .pattern) return p.last_pattern;
        return if (pipeline.commands[0].argv.len > 0) pipeline.commands[0].argv[0] else "";
    }

    fn execLine(self: *Shell, arena: std.mem.Allocator, line: []const u8, lines: ?parser.LineSource) anyerror!Flow {
        var p = parser.Parser.init(arena, line);
        p.lines = lines;
        p.substitute = .{ .context = self, .run = captureOutput, .status = &self.substitution_status };
        while (try p.next(self.last_status)) |pipeline| {
            const should_run = switch (pipeline.join) {
                .always => true,
                .and_if => self.last_status == 0,
                .or_if => self.last_status != 0,
            };
            if (!should_run) continue;
            const chained = p.pending_join != .always;
            if (chained) self.errexit_suspend += 1;
            const outcome = self.runPipeline(arena, pipeline);
            if (chained) self.errexit_suspend -= 1;
            switch (try outcome) {
                .status => |status| self.last_status = status,
                .exit => |code| return .{ .exit = code },
                .loop_break => |levels| return .{ .break_loop = levels },
                .loop_continue => |levels| return .{ .continue_loop = levels },
                .fn_return => |code| return .{ .return_fn = code },
            }
            if (sigint_seen) {
                sigint_seen = false;
                return .interrupted;
            }
            if (self.errexit and self.errexit_suspend == 0 and p.pending_join == .always and self.last_status != 0) {
                return .{ .exit = self.last_status };
            }
        }
        return .normal;
    }

    fn runPipeline(self: *Shell, arena: std.mem.Allocator, pipeline: parser.Pipeline) !Outcome {
        const cmds = pipeline.commands;
        if (cmds.len == 1) {
            const cmd = cmds[0];
            const is_function = cmd.argv.len > 0 and functions.has(cmd.argv[0]);
            if (cmd.argv.len == 0 or is_function or isBuiltin(cmd.argv[0])) {
                const saved = saveStandardFds();
                defer restoreStandardFds(saved);
                if (!applyRedirects(cmd.redirects)) return .{ .status = 1 };
                if (cmd.argv.len == 0) return .{ .status = assign(cmd.assignments) };
                if (is_function) return self.callFunction(cmd.argv);
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
        if (functions.has(cmd.argv[0])) {
            const outcome = self.callFunction(cmd.argv) catch posix.exit(1);
            switch (outcome) {
                .status, .exit, .fn_return => |code| posix.exit(code),
                else => posix.exit(0),
            }
        }
        if (self.builtin(arena, cmd.argv)) |outcome| {
            switch (outcome) {
                .status => |status| posix.exit(status),
                .exit => |code| posix.exit(code),
                .fn_return => |code| posix.exit(code),
                else => posix.exit(0),
            }
        }
        execute(arena, cmd);
    }

    pub fn expandText(self: *Shell, arena: std.mem.Allocator, text: []const u8) []const u8 {
        var p = parser.Parser.init(arena, text);
        p.last_status = self.last_status;
        p.substitute = .{ .context = self, .run = captureOutput, .status = &self.substitution_status };
        return p.expandBody(text) catch text;
    }

    fn callFunction(self: *Shell, argv: []const []const u8) anyerror!Outcome {
        if (self.call_depth >= max_call_depth) {
            printError("{s}: maximum function nesting level exceeded ({d})", .{ argv[0], max_call_depth });
            return .{ .status = 1 };
        }
        var scope = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scope.deinit();
        const arena = scope.allocator();
        const source = try arena.dupe(u8, functions.get(argv[0]).?);
        const list = ast.parse(arena, source) catch {
            printError("{s}: invalid function body", .{argv[0]});
            return .{ .status = 2 };
        };
        try vars.pushFrame(argv[1..]);
        defer vars.popFrame();
        self.call_depth += 1;
        defer self.call_depth -= 1;
        const flow = try self.execList(arena, list, null);
        return switch (flow) {
            .normal, .break_loop, .continue_loop => .{ .status = self.last_status },
            .return_fn => |code| .{ .status = code },
            .exit => |code| .{ .exit = code },
            .interrupted => blk: {
                sigint_seen = true;
                break :blk .{ .status = 130 };
            },
        };
    }

    fn sourceFile(self: *Shell, args: []const []const u8) Outcome {
        if (args.len > 1) {
            printError("source: too many arguments", .{});
            return .{ .status = 2 };
        }
        if (self.source_depth >= max_call_depth) {
            printError("source: maximum nesting level exceeded ({d})", .{max_call_depth});
            return .{ .status = 1 };
        }
        var default_buf: [std.fs.max_path_bytes]u8 = undefined;
        var path: []const u8 = undefined;
        var label: []const u8 = "~/.zsrc";
        if (args.len == 1) {
            path = args[0];
            label = args[0];
        } else {
            const home = vars.get("HOME") orelse {
                printError("source: HOME is not set", .{});
                return .{ .status = 1 };
            };
            path = std.fmt.bufPrint(&default_buf, "{s}/.zsrc", .{home}) catch return .{ .status = 1 };
        }
        self.source_depth += 1;
        defer self.source_depth -= 1;
        const result = rc.runFile(std.heap.page_allocator, self, path, label) catch |err| {
            printError("source: {s}: {s}", .{ label, describe(err) });
            return .{ .status = 1 };
        };
        if (result) |code| return .{ .exit = code };
        return .{ .status = self.last_status };
    }

    fn setOptions(self: *Shell, arena: std.mem.Allocator, args: []const []const u8) u8 {
        if (args.len == 0) {
            const names = vars.variableNames(arena) catch return 1;
            const stdout = std.io.getStdOut().writer();
            for (names) |name| {
                stdout.print("{s}={s}\n", .{ name, vars.get(name) orelse "" }) catch return 1;
            }
            return 0;
        }
        var index: usize = 0;
        var set_params = false;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--")) {
                index += 1;
                set_params = true;
                break;
            }
            if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) {
                set_params = true;
                break;
            }
            const enable = arg[0] == '-';
            if (arg[1] == 'o' and arg.len == 2) {
                index += 1;
                if (index >= args.len) {
                    printError("set: -o: option requires an argument", .{});
                    return 2;
                }
                if (!self.setOption(optionLetter(args[index]), enable, args[index])) return 2;
                continue;
            }
            for (arg[1..]) |letter| {
                if (!self.setOption(letter, enable, arg)) return 2;
            }
        }
        if (set_params) {
            vars.setParams(args[index..]) catch {
                printError("out of memory", .{});
                return 1;
            };
        }
        return 0;
    }

    fn setOption(self: *Shell, letter: u8, enable: bool, original: []const u8) bool {
        switch (letter) {
            'e' => self.errexit = enable,
            'u' => vars.nounset = enable,
            else => {
                printError("set: {s}: invalid option", .{original});
                return false;
            },
        }
        return true;
    }

    fn returnFromFunction(self: *Shell, args: []const []const u8) Outcome {
        if (self.call_depth == 0) {
            printError("return: can only return from a function", .{});
            return .{ .status = 1 };
        }
        if (args.len == 0) return .{ .fn_return = self.last_status };
        const code = std.fmt.parseInt(i64, args[0], 10) catch {
            printError("return: {s}: numeric argument required", .{args[0]});
            return .{ .fn_return = 2 };
        };
        return .{ .fn_return = @intCast(@mod(code, 256)) };
    }

    fn builtin(self: *Shell, arena: std.mem.Allocator, argv: []const []const u8) ?Outcome {
        const name = argv[0];
        if (std.mem.eql(u8, name, "cd")) return .{ .status = changeDirectory(argv[1..]) };
        if (std.mem.eql(u8, name, "exit")) return exitShell(self.last_status, argv[1..]);
        if (std.mem.eql(u8, name, ":")) return .{ .status = 0 };
        if (std.mem.eql(u8, name, "exec")) return .{ .status = replaceProcess(arena, argv[1..]) };
        if (std.mem.eql(u8, name, "set")) return .{ .status = self.setOptions(arena, argv[1..]) };
        if (std.mem.eql(u8, name, "source") or std.mem.eql(u8, name, ".")) return self.sourceFile(argv[1..]);
        if (std.mem.eql(u8, name, "zsprompt")) return .{ .status = promptCommand(arena, argv[1..]) };
        if (std.mem.eql(u8, name, "shift")) return .{ .status = shiftParameters(argv[1..]) };
        if (std.mem.eql(u8, name, "local")) return .{ .status = localVariables(argv[1..]) };
        if (std.mem.eql(u8, name, "return")) return self.returnFromFunction(argv[1..]);
        if (std.mem.eql(u8, name, "read")) return .{ .status = readLine(argv[1..]) };
        if (std.mem.eql(u8, name, "break")) return loopControl(argv[1..], true);
        if (std.mem.eql(u8, name, "continue")) return loopControl(argv[1..], false);
        if (std.mem.eql(u8, name, "export")) return .{ .status = exportVariables(arena, argv[1..]) };
        if (std.mem.eql(u8, name, "unset")) return .{ .status = unsetVariables(argv[1..]) };
        return null;
    }
};

fn captureOutput(context: *anyopaque, arena: std.mem.Allocator, command: []const u8) parser.Error![]const u8 {
    const self: *Shell = @ptrCast(@alignCast(context));
    const fds = posix.pipe() catch return error.SubstitutionFailed;
    const pid = posix.fork() catch {
        posix.close(fds[0]);
        posix.close(fds[1]);
        return error.SubstitutionFailed;
    };
    if (pid == 0) {
        restoreDefaultSignals();
        posix.close(fds[0]);
        posix.dup2(fds[1], posix.STDOUT_FILENO) catch posix.exit(1);
        posix.close(fds[1]);
        const code = self.run(arena, command, null) catch posix.exit(1);
        posix.exit(code orelse self.last_status);
    }
    posix.close(fds[1]);
    var output = std.ArrayList(u8).init(arena);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fds[0], &buf) catch break;
        if (n == 0) break;
        try output.appendSlice(buf[0..n]);
    }
    posix.close(fds[0]);
    var interrupted = false;
    self.substitution_status = reap(pid, &interrupted);
    return std.mem.trimRight(u8, output.items, "\n");
}

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

fn readLine(args: []const []const u8) u8 {
    var raw = false;
    var prompt: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "-r")) {
            raw = true;
        } else if (std.mem.eql(u8, args[i], "-p")) {
            i += 1;
            if (i >= args.len) {
                printError("read: -p: option requires an argument", .{});
                return 2;
            }
            prompt = args[i];
        } else if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        } else {
            printError("read: {s}: invalid option", .{args[i]});
            return 2;
        }
    }
    const names = args[i..];
    for (names) |name| {
        if (!parser.isName(name)) {
            printError("read: '{s}': not a valid identifier", .{name});
            return 1;
        }
    }
    if (prompt) |text| std.io.getStdErr().writeAll(text) catch {};

    var line = std.ArrayList(u8).init(std.heap.page_allocator);
    defer line.deinit();
    var reached_eof = false;
    var byte: [1]u8 = undefined;
    while (true) {
        const count = posix.read(posix.STDIN_FILENO, &byte) catch 0;
        if (count == 0) {
            reached_eof = true;
            break;
        }
        if (byte[0] == '\n') break;
        if (!raw and byte[0] == '\\') {
            const escaped = posix.read(posix.STDIN_FILENO, &byte) catch 0;
            if (escaped == 0) {
                reached_eof = true;
                break;
            }
            if (byte[0] == '\n') continue;
        }
        line.append(byte[0]) catch return 1;
    }

    const ifs = vars.get("IFS") orelse " \t\n";
    if (names.len == 0) {
        vars.set("REPLY", line.items) catch return 1;
    } else {
        var rest: []const u8 = line.items;
        for (names, 0..) |name, index| {
            rest = std.mem.trimLeft(u8, rest, ifs);
            if (index + 1 == names.len) {
                vars.set(name, std.mem.trimRight(u8, rest, ifs)) catch return 1;
                rest = "";
            } else {
                const end = std.mem.indexOfAny(u8, rest, ifs) orelse rest.len;
                vars.set(name, rest[0..end]) catch return 1;
                rest = rest[end..];
            }
        }
    }
    return if (reached_eof) 1 else 0;
}

fn loopControl(args: []const []const u8, is_break: bool) Outcome {
    var levels: u8 = 1;
    if (args.len > 0) {
        levels = std.fmt.parseInt(u8, args[0], 10) catch 0;
        if (levels == 0) {
            printError("{s}: {s}: loop count out of range", .{ if (is_break) "break" else "continue", args[0] });
            return .{ .status = 1 };
        }
    }
    return if (is_break) .{ .loop_break = levels } else .{ .loop_continue = levels };
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

fn promptCommand(arena: std.mem.Allocator, args: []const []const u8) u8 {
    const stdout = std.io.getStdOut().writer();
    if (args.len == 0) {
        stdout.print("{s}\n", .{prompts.format()}) catch return 1;
        return 0;
    }
    if (args.len > 1) {
        printError("zsprompt: too many arguments (quote the format)", .{});
        return 2;
    }
    const arg = args[0];
    if (std.mem.eql(u8, arg, "--reset")) {
        prompts.reset();
        return 0;
    }
    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
        stdout.writeAll(prompts.help) catch return 1;
        return 0;
    }
    if (std.mem.startsWith(u8, arg, "--")) {
        printError("zsprompt: {s}: invalid option", .{arg});
        return 2;
    }
    const unknown = prompts.unknownEscapes(arena, arg) catch return 1;
    if (unknown.len > 0) diag.warning("zsprompt: unknown escapes kept literally: {s}", .{unknown});
    prompts.setFormat(arg) catch {
        printError("out of memory", .{});
        return 1;
    };
    return 0;
}

fn optionLetter(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "errexit")) return 'e';
    if (std.mem.eql(u8, name, "nounset")) return 'u';
    return 0;
}

fn shiftParameters(args: []const []const u8) u8 {
    var count: usize = 1;
    if (args.len > 0) {
        count = std.fmt.parseInt(usize, args[0], 10) catch {
            printError("shift: {s}: numeric argument required", .{args[0]});
            return 2;
        };
    }
    if (vars.shift(count)) return 0;
    if (args.len > 0) printError("shift: shift count out of range", .{});
    return 1;
}

fn localVariables(args: []const []const u8) u8 {
    if (!vars.inFunction()) {
        printError("local: can only be used in a function", .{});
        return 1;
    }
    var status: u8 = 0;
    for (args) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (eq) |i| arg[0..i] else arg;
        if (!parser.isName(name)) {
            printError("local: '{s}': not a valid identifier", .{arg});
            status = 1;
            continue;
        }
        vars.declareLocal(name) catch {
            printError("out of memory", .{});
            return 1;
        };
        if (eq) |i| vars.set(name, arg[i + 1 ..]) catch {
            printError("out of memory", .{});
            return 1;
        };
    }
    return status;
}

fn unsetVariables(args: []const []const u8) u8 {
    var status: u8 = 0;
    var names = args;
    var functions_only = false;
    while (names.len > 0 and (std.mem.eql(u8, names[0], "-f") or std.mem.eql(u8, names[0], "-v"))) {
        functions_only = names[0][1] == 'f';
        names = names[1..];
    }
    for (names) |name| {
        if (functions_only) {
            _ = functions.remove(name);
            continue;
        }
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

fn replaceProcess(arena: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len == 0) return 0;
    restoreDefaultSignals();
    execute(arena, .{ .argv = args });
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
        if (sig == posix.SIG.INT) {
            interrupted.* = true;
            sigint_seen = true;
        }
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
