const std = @import("std");
const wrap = @import("wrap.zig");

fn expectFragment(it: *wrap.Iterator, text: []const u8, expected: []const u8, columns: usize) !void {
    const fragment = it.next().?;
    try std.testing.expectEqual(wrap.Kind.text, fragment.kind);
    try std.testing.expectEqualStrings(expected, text[fragment.start..fragment.end]);
    try std.testing.expectEqual(columns, fragment.columns);
}

test "cell wrapping retains complete grapheme clusters" {
    const text = "a e\u{301} 世";
    var it = try wrap.iterator(text, 2, .cell);
    try expectFragment(&it, text, "a ", 2);
    try expectFragment(&it, text, "e\u{301} ", 2);
    try expectFragment(&it, text, "世", 2);
    try std.testing.expect(it.next() == null);
}

test "wrapping handles forced lines and final empty lines" {
    const text = "ab\ncd\n";
    var it = try wrap.iterator(text, 2, .cell);
    try expectFragment(&it, text, "ab", 2);
    try expectFragment(&it, text, "cd", 2);
    try expectFragment(&it, text, "", 0);
    try std.testing.expect(it.next() == null);
}

test "an exact-width row does not consume the next text cluster" {
    const text = "abx";
    var it = try wrap.iterator(text, 2, .cell);
    try expectFragment(&it, text, "ab", 2);
    try expectFragment(&it, text, "x", 1);
    try std.testing.expect(it.next() == null);
}

test "narrow rows replace one too-wide cluster" {
    const text = "世x";
    var it = try wrap.iterator(text, 1, .cell);
    const replacement = it.next().?;
    try std.testing.expectEqual(wrap.Kind.replacement, replacement.kind);
    try std.testing.expectEqualStrings("世", text[replacement.start..replacement.end]);
    try expectFragment(&it, text, "x", 1);
    try std.testing.expectError(error.ZeroColumns, wrap.iterator(text, 0, .cell));
}

test "word wrapping follows Unicode line-break opportunities" {
    // U+00A0 is intentionally non-breaking. Treating every whitespace
    // cluster as a word boundary would split this before `b`.
    const text = "a\u{00a0}b c";
    var it = try wrap.iterator(text, 2, .word);
    try expectFragment(&it, text, "a\u{00a0}", 2);
    try expectFragment(&it, text, "b ", 2);
    try expectFragment(&it, text, "c", 1);
    try std.testing.expect(it.next() == null);
}

test "wrapping recognizes Unicode mandatory line breaks" {
    const text = "a\rb\u{0085}c\u{2028}d\u{2029}";
    var it = try wrap.iterator(text, 4, .cell);
    try expectFragment(&it, text, "a", 1);
    try expectFragment(&it, text, "b", 1);
    try expectFragment(&it, text, "c", 1);
    try expectFragment(&it, text, "d", 1);
    try expectFragment(&it, text, "", 0);
    try std.testing.expect(it.next() == null);
}

test "both wrapping modes retain empty input and trailing CRLF rows" {
    for ([_]wrap.Mode{ .cell, .word }) |mode| {
        var empty = try wrap.iterator("", 2, mode);
        try expectFragment(&empty, "", "", 0);
        try std.testing.expect(empty.next() == null);

        const text = "ab\r\n\r\n";
        var it = try wrap.iterator(text, 2, mode);
        try expectFragment(&it, text, "ab", 2);
        try expectFragment(&it, text, "", 0);
        try expectFragment(&it, text, "", 0);
        try std.testing.expect(it.next() == null);
    }
}

test "measured replacement clusters occupy one column in both wrapping modes" {
    for ([_]wrap.Mode{ .cell, .word }) |mode| {
        const text = "a\u{903}\u{903}x";
        var it = try wrap.iterator(text, 1, mode);
        // Screen renders this non-renderable cluster as one question mark.
        try expectFragment(&it, text, "a\u{903}\u{903}", 1);
        try expectFragment(&it, text, "x", 1);
        try std.testing.expect(it.next() == null);
    }
}
