const std = @import("std");
const width = @import("width.zig");
const table = @import("width_table.zig");

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

test "fitPrefix truncates narrow text by column" {
    const f = width.fitPrefix("hello", 3);
    try expectEqual(@as(usize, 3), f.len);
    try expectEqual(@as(usize, 3), f.width);
}

test "fitPrefix excludes a wide character that would straddle the edge" {
    // Two wide characters need four columns. In three, only the first fits,
    // and the reported width is one less than the limit. The caller pads.
    const f = width.fitPrefix("世界", 3);
    try expectEqual(@as(usize, 3), f.len); // one 3-byte character
    try expectEqual(@as(usize, 2), f.width);
}

test "fitPrefix with a zero limit takes nothing" {
    const f = width.fitPrefix("anything", 0);
    try expectEqual(@as(usize, 0), f.len);
    try expectEqual(@as(usize, 0), f.width);
}

test "fitPrefix passes through text that already fits" {
    const f = width.fitPrefix("hi", 80);
    try expectEqual(@as(usize, 2), f.len);
    try expectEqual(@as(usize, 2), f.width);
}

test "invalid UTF-8 counts one column per bad byte" {
    try expectEqual(@as(usize, 2), width.strWidth("\xff\xfe"));
}

test "a truncated sequence does not read past the end" {
    // "\xe4\xb8" is the first two bytes of a three-byte character. A decoder
    // that trusts utf8ByteSequenceLength without checking what remains reads
    // out of bounds here.
    try expectEqual(@as(usize, 2), width.strWidth("\xe4\xb8"));
    const f = width.fitPrefix("\xe4\xb8", 10);
    try expectEqual(@as(usize, 2), f.len);
}

test "invalid bytes never stall the scan" {
    // Every input must terminate and consume its whole length.
    const inputs = [_][]const u8{
        "\xff", "\x80", "\xf8\xf8", "a\xffb", "\xe4\xb8\x96\xff", "\xc2",
    };
    for (inputs) |s| {
        _ = width.strWidth(s);
        const f = width.fitPrefix(s, 100);
        try expect(f.len <= s.len);
    }
}

test "emoji are two columns" {
    try expectEqual(@as(u2, 2), width.codepointWidth(0x1F642)); // slightly smiling face
}
