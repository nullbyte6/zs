const std = @import("std");
const vars = @import("vars.zig");

pub const Error = error{ Syntax, DivideByZero };

pub fn eval(text: []const u8) Error!i64 {
    return evaluate(text, false);
}

pub fn calculate(text: []const u8) Error!i64 {
    return evaluate(text, true);
}

pub fn looksLikeExpression(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (trimmed.len == 0) return false;
    const first = trimmed[0];
    if (!(std.ascii.isDigit(first) or first == '(' or first == '-' or first == '+')) return false;
    var has_digit = false;
    for (trimmed) |c| {
        if (std.ascii.isDigit(c)) {
            has_digit = true;
        } else if (std.mem.indexOfScalar(u8, "+-*/%() \t", c) == null) {
            return false;
        }
    }
    return has_digit;
}

fn evaluate(text: []const u8, calculator: bool) Error!i64 {
    if (std.mem.trim(u8, text, " \t\n").len == 0) return 0;
    var evaluator = Evaluator{ .text = text, .calculator = calculator };
    const value = try evaluator.assignment();
    evaluator.skip();
    if (evaluator.pos != text.len) return error.Syntax;
    return value;
}

const BinaryOp = struct {
    text: []const u8,
    prec: u8,
    right: bool = false,
};

const binary_ops = [_]BinaryOp{
    .{ .text = "**", .prec = 11, .right = true },
    .{ .text = "<<", .prec = 8 },
    .{ .text = ">>", .prec = 8 },
    .{ .text = "<=", .prec = 7 },
    .{ .text = ">=", .prec = 7 },
    .{ .text = "==", .prec = 6 },
    .{ .text = "!=", .prec = 6 },
    .{ .text = "&&", .prec = 2 },
    .{ .text = "||", .prec = 1 },
    .{ .text = "*", .prec = 10 },
    .{ .text = "/", .prec = 10 },
    .{ .text = "%", .prec = 10 },
    .{ .text = "+", .prec = 9 },
    .{ .text = "-", .prec = 9 },
    .{ .text = "<", .prec = 7 },
    .{ .text = ">", .prec = 7 },
    .{ .text = "&", .prec = 5 },
    .{ .text = "^", .prec = 4 },
    .{ .text = "|", .prec = 3 },
};

const Evaluator = struct {
    text: []const u8,
    pos: usize = 0,
    calculator: bool = false,

    fn skip(self: *Evaluator) void {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
    }

    fn startsWith(self: *Evaluator, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.text[self.pos..], prefix);
    }

    fn identifier(self: *Evaluator) ?[]const u8 {
        const start = self.pos;
        var end = start;
        while (end < self.text.len) : (end += 1) {
            const c = self.text[end];
            if (!(c == '_' or std.ascii.isAlphabetic(c) or (end > start and std.ascii.isDigit(c)))) break;
        }
        if (end == start) return null;
        self.pos = end;
        return self.text[start..end];
    }

    fn assignment(self: *Evaluator) Error!i64 {
        self.skip();
        const save = self.pos;
        if (self.identifier()) |name| {
            self.skip();
            const ops = [_][]const u8{ "+=", "-=", "*=", "/=", "%=", "=" };
            for (ops) |op| {
                if (!self.startsWith(op)) continue;
                if (op.len == 1 and self.startsWith("==")) continue;
                self.pos += op.len;
                const rhs = try self.assignment();
                const result = if (op.len == 1) rhs else try combine(op[0..1], lookup(name), rhs);
                try store(name, result);
                return result;
            }
        }
        self.pos = save;
        return self.ternary();
    }

    fn ternary(self: *Evaluator) Error!i64 {
        const condition = try self.binary(1);
        self.skip();
        if (self.pos < self.text.len and self.text[self.pos] == '?') {
            self.pos += 1;
            const when_true = try self.assignment();
            self.skip();
            if (self.pos >= self.text.len or self.text[self.pos] != ':') return error.Syntax;
            self.pos += 1;
            const when_false = try self.assignment();
            return if (condition != 0) when_true else when_false;
        }
        return condition;
    }

    fn binary(self: *Evaluator, min_prec: u8) Error!i64 {
        var left = try self.unary();
        while (true) {
            self.skip();
            var implied = false;
            const op = self.peekOp() orelse if (self.calculator and self.pos < self.text.len and self.text[self.pos] == '(') blk: {
                implied = true;
                break :blk BinaryOp{ .text = "*", .prec = 10 };
            } else break;
            if (op.prec < min_prec) break;
            if (!implied) self.pos += op.text.len;
            const right = try self.binary(if (op.right) op.prec else op.prec + 1);
            left = try combine(op.text, left, right);
        }
        return left;
    }

    fn peekOp(self: *Evaluator) ?BinaryOp {
        for (binary_ops) |op| {
            if (self.startsWith(op.text)) return op;
        }
        return null;
    }

    fn unary(self: *Evaluator) Error!i64 {
        self.skip();
        if (self.pos >= self.text.len) return error.Syntax;
        if (self.startsWith("++") or self.startsWith("--")) {
            const delta: i64 = if (self.text[self.pos] == '+') 1 else -1;
            self.pos += 2;
            self.skip();
            const name = self.identifier() orelse return error.Syntax;
            const updated = lookup(name) +% delta;
            try store(name, updated);
            return updated;
        }
        switch (self.text[self.pos]) {
            '+' => {
                self.pos += 1;
                return self.unary();
            },
            '-' => {
                self.pos += 1;
                if (self.calculator) return 0 -% try self.binary(11);
                return 0 -% try self.unary();
            },
            '!' => {
                self.pos += 1;
                return @intFromBool(try self.unary() == 0);
            },
            '~' => {
                self.pos += 1;
                return ~(try self.unary());
            },
            else => return self.primary(),
        }
    }

    fn primary(self: *Evaluator) Error!i64 {
        self.skip();
        if (self.pos >= self.text.len) return error.Syntax;
        const c = self.text[self.pos];
        if (c == '(') {
            self.pos += 1;
            const value = try self.assignment();
            self.skip();
            if (self.pos >= self.text.len or self.text[self.pos] != ')') return error.Syntax;
            self.pos += 1;
            return value;
        }
        if (std.ascii.isDigit(c)) return self.number();
        if (c == '$') {
            self.pos += 1;
            if (self.pos < self.text.len and self.text[self.pos] == '{') {
                const end = std.mem.indexOfScalarPos(u8, self.text, self.pos, '}') orelse return error.Syntax;
                const name = self.text[self.pos + 1 .. end];
                self.pos = end + 1;
                return lookup(name);
            }
            return lookup(self.identifier() orelse return error.Syntax);
        }
        const name = self.identifier() orelse return error.Syntax;
        if (self.startsWith("++") or self.startsWith("--")) {
            const delta: i64 = if (self.text[self.pos] == '+') 1 else -1;
            self.pos += 2;
            const old = lookup(name);
            try store(name, old +% delta);
            return old;
        }
        return lookup(name);
    }

    fn number(self: *Evaluator) Error!i64 {
        const start = self.pos;
        while (self.pos < self.text.len and std.ascii.isAlphanumeric(self.text[self.pos])) self.pos += 1;
        const token = self.text[start..self.pos];
        if (token.len > 2 and token[0] == '0' and (token[1] == 'x' or token[1] == 'X')) {
            return std.fmt.parseInt(i64, token[2..], 16) catch error.Syntax;
        }
        if (token.len > 1 and token[0] == '0') return std.fmt.parseInt(i64, token, 8) catch error.Syntax;
        return std.fmt.parseInt(i64, token, 10) catch error.Syntax;
    }
};

fn combine(op: []const u8, a: i64, b: i64) Error!i64 {
    if (std.mem.eql(u8, op, "+")) return a +% b;
    if (std.mem.eql(u8, op, "-")) return a -% b;
    if (std.mem.eql(u8, op, "*")) return a *% b;
    if (std.mem.eql(u8, op, "/")) {
        if (b == 0) return error.DivideByZero;
        return @divTrunc(a, b);
    }
    if (std.mem.eql(u8, op, "%")) {
        if (b == 0) return error.DivideByZero;
        return @rem(a, b);
    }
    if (std.mem.eql(u8, op, "**")) {
        if (b < 0) return if (a == 1) 1 else if (a == -1) (if (@mod(b, 2) == 0) 1 else -1) else 0;
        var result: i64 = 1;
        var base = a;
        var exponent = b;
        while (exponent > 0) : (exponent >>= 1) {
            if (exponent & 1 == 1) result *%= base;
            base *%= base;
        }
        return result;
    }
    if (std.mem.eql(u8, op, "<<")) return a << @as(u6, @intCast(b & 63));
    if (std.mem.eql(u8, op, ">>")) return a >> @as(u6, @intCast(b & 63));
    if (std.mem.eql(u8, op, "<=")) return @intFromBool(a <= b);
    if (std.mem.eql(u8, op, ">=")) return @intFromBool(a >= b);
    if (std.mem.eql(u8, op, "==")) return @intFromBool(a == b);
    if (std.mem.eql(u8, op, "!=")) return @intFromBool(a != b);
    if (std.mem.eql(u8, op, "<")) return @intFromBool(a < b);
    if (std.mem.eql(u8, op, ">")) return @intFromBool(a > b);
    if (std.mem.eql(u8, op, "&&")) return @intFromBool(a != 0 and b != 0);
    if (std.mem.eql(u8, op, "||")) return @intFromBool(a != 0 or b != 0);
    if (std.mem.eql(u8, op, "&")) return a & b;
    if (std.mem.eql(u8, op, "^")) return a ^ b;
    if (std.mem.eql(u8, op, "|")) return a | b;
    return error.Syntax;
}

fn lookup(name: []const u8) i64 {
    const value = vars.get(name) orelse return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, value, " \t"), 10) catch 0;
}

fn store(name: []const u8, value: i64) Error!void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.Syntax;
    vars.set(name, text) catch return error.Syntax;
}
