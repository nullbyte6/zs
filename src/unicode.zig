const std = @import("std");

pub const Glyph = struct {
    len: usize,
    width: usize,
};

const Range = struct { lo: u21, hi: u21 };

const zero_width = [_]Range{
    .{ .lo = 0x0300, .hi = 0x036f },
    .{ .lo = 0x0483, .hi = 0x0489 },
    .{ .lo = 0x0591, .hi = 0x05bd },
    .{ .lo = 0x1ab0, .hi = 0x1aff },
    .{ .lo = 0x1dc0, .hi = 0x1dff },
    .{ .lo = 0x200b, .hi = 0x200f },
    .{ .lo = 0x2028, .hi = 0x202e },
    .{ .lo = 0x2060, .hi = 0x2064 },
    .{ .lo = 0x20d0, .hi = 0x20ff },
    .{ .lo = 0xfe00, .hi = 0xfe0f },
    .{ .lo = 0xfe20, .hi = 0xfe2f },
    .{ .lo = 0xe0100, .hi = 0xe01ef },
};

const double_width = [_]Range{
    .{ .lo = 0x1100, .hi = 0x115f },
    .{ .lo = 0x2e80, .hi = 0x303e },
    .{ .lo = 0x3041, .hi = 0x33ff },
    .{ .lo = 0x3400, .hi = 0x4dbf },
    .{ .lo = 0x4e00, .hi = 0x9fff },
    .{ .lo = 0xa000, .hi = 0xa4cf },
    .{ .lo = 0xac00, .hi = 0xd7a3 },
    .{ .lo = 0xf900, .hi = 0xfaff },
    .{ .lo = 0xfe30, .hi = 0xfe6f },
    .{ .lo = 0xff00, .hi = 0xff60 },
    .{ .lo = 0xffe0, .hi = 0xffe6 },
    .{ .lo = 0x1f300, .hi = 0x1f64f },
    .{ .lo = 0x1f680, .hi = 0x1f6ff },
    .{ .lo = 0x1f900, .hi = 0x1f9ff },
    .{ .lo = 0x1fa70, .hi = 0x1faff },
    .{ .lo = 0x20000, .hi = 0x3fffd },
};

pub fn width(cp: u21) usize {
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    if (cp < 0x300) return 1;
    if (inRanges(&zero_width, cp)) return 0;
    if (inRanges(&double_width, cp)) return 2;
    return 1;
}

pub fn glyphAt(bytes: []const u8, index: usize) Glyph {
    const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return .{ .len = 1, .width = 1 };
    if (index + len > bytes.len) return .{ .len = 1, .width = 1 };
    const cp = std.unicode.utf8Decode(bytes[index .. index + len]) catch return .{ .len = 1, .width = 1 };
    return .{ .len = len, .width = width(cp) };
}

fn inRanges(ranges: []const Range, cp: u21) bool {
    for (ranges) |r| {
        if (cp >= r.lo and cp <= r.hi) return true;
    }
    return false;
}
