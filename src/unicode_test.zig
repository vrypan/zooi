const std = @import("std");
const unicode = @import("unicode/root.zig");

test "invalid UTF-8 always makes progress" {
    const bytes = [_]u8{ 0xff, 0xe2, 0x82, 'x' };
    var pos: usize = 0;
    while (pos < bytes.len) {
        const step = unicode.utf8.step(bytes[pos..]);
        try std.testing.expect(step.len > 0);
        pos += step.len;
    }
}

test "graphemes retain combining, flags, and emoji ZWJ sequences" {
    const text = "e\u{301}🇬🇷👩‍💻";
    var it = unicode.grapheme.iterator(text);
    const first = it.next().?;
    const second = it.next().?;
    const third = it.next().?;
    try std.testing.expectEqualStrings("e\u{301}", text[first.start..first.end]);
    try std.testing.expectEqualStrings("🇬🇷", text[second.start..second.end]);
    try std.testing.expectEqualStrings("👩‍💻", text[third.start..third.end]);
    try std.testing.expect(it.next() == null);
}

test "cluster widths use the terminal policy" {
    try std.testing.expectEqual(@as(u3, 1), unicode.width.measureCluster("e\u{301}").columns);
    try std.testing.expectEqual(@as(u3, 2), unicode.width.measureCluster("世").columns);
    try std.testing.expectEqual(@as(u3, 2), unicode.width.measureCluster("👩‍💻").columns);
    try std.testing.expectEqual(@as(usize, 3), unicode.width.textWidth("e\u{301}👩‍💻"));
}
