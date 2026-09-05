const std = @import("std");
const width = @import("width.zig");
const table = @import("unicode/tables.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "ASCII is one column per byte" {
    try expectEqual(@as(usize, 5), width.strWidth("hello"));
    try expectEqual(@as(u2, 1), width.codepointWidth('a'));
    try expectEqual(@as(u2, 1), width.codepointWidth(' '));
}

test "bytes and columns are different things" {
    // The distinction this whole module exists for, asserted in one place.
    try expectEqual(@as(usize, 2), "é".len);
    try expectEqual(@as(usize, 1), width.strWidth("é"));

    try expectEqual(@as(usize, 3), "世".len);
    try expectEqual(@as(usize, 2), width.strWidth("世"));
}

test "East Asian wide characters are two columns" {
    try expectEqual(@as(u2, 2), width.codepointWidth('世'));
    try expectEqual(@as(usize, 4), width.strWidth("世界"));
    // Fullwidth forms too.
    try expectEqual(@as(u2, 2), width.codepointWidth('Ａ'));
}

test "combining marks are zero columns" {
    try expectEqual(@as(u2, 0), width.codepointWidth(0x0301)); // combining acute
    try expectEqual(@as(usize, 1), width.strWidth("e\u{0301}"));
}

test "U+00AD is the exception to the format-character rule" {
    // Category Cf, but terminals draw it, so it must not be zero.
    try expectEqual(@as(u2, 1), width.codepointWidth(0x00AD));
}

test "table invariants hold" {
    // A binary search is only correct over sorted, disjoint ranges.
    for ([_][]const table.Range{ &table.zero_width, &table.wide }) |ranges| {
        try expect(ranges.len > 0);
        var prev_hi: i32 = -1;
        for (ranges) |r| {
            try expect(r.lo <= r.hi);
            try expect(@as(i32, r.lo) > prev_hi);
            prev_hi = @intCast(r.hi);
        }
    }
}

test "step advances one codepoint at a time" {
    const s1 = width.step("abc");
    try expectEqual(@as(usize, 1), s1.len);
    try expectEqual(@as(u2, 1), s1.width);
    try expectEqual(@as(u21, 'a'), s1.cp.?);

    const s2 = width.step("世界");
    try expectEqual(@as(usize, 3), s2.len);
    try expectEqual(@as(u2, 2), s2.width);
    try expectEqual(@as(u21, 0x4E16), s2.cp.?);
}

test "step reports no codepoint for malformed bytes" {
    // The screen relies on `cp` being null here so it can drop the byte
    // without mistaking it for a control character.
    try expect(width.step("\xff").cp == null);
    try expect(width.step("\x80").cp == null);
    // Truncated: a valid lead with too few bytes behind it.
    try expect(width.step("\xe4\xb8").cp == null);
}

test "step always advances" {
    // The property every caller's loop depends on for termination.
    const inputs = [_][]const u8{ "\xff", "\x80", "\xc2", "\xe4\xb8", "a", "世" };
    for (inputs) |s| try expect(width.step(s).len >= 1);
}

test "invalid UTF-8 is ignored to match Screen" {
    try expectEqual(@as(usize, 0), width.strWidth("\xff\xfe"));
}

test "a truncated sequence does not read past the end" {
    // "\xe4\xb8" is the first two bytes of a three-byte character. A decoder
    // that trusts utf8ByteSequenceLength without checking what remains reads
    // out of bounds here.
    try expectEqual(@as(usize, 0), width.strWidth("\xe4\xb8"));
}

test "invalid bytes never stall the scan" {
    // Every input must terminate and consume its whole length.
    const inputs = [_][]const u8{
        "\xff", "\x80", "\xf8\xf8", "a\xffb", "\xe4\xb8\x96\xff", "\xc2",
    };
    for (inputs) |s| {
        _ = width.strWidth(s);
        try expect(width.step(s).len <= s.len);
    }
}

test "emoji are two columns" {
    try expectEqual(@as(u2, 2), width.codepointWidth(0x1F642)); // slightly smiling face
}
