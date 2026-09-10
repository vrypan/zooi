const std = @import("std");
const unicode = @import("zunic");

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
    var it = unicode.text(text).graphemes().iterator();
    const first = it.next().?;
    const second = it.next().?;
    const third = it.next().?;
    try std.testing.expectEqualStrings("e\u{301}", text[first.start.value..first.end.value]);
    try std.testing.expectEqualStrings("🇬🇷", text[second.start.value..second.end.value]);
    try std.testing.expectEqualStrings("👩‍💻", text[third.start.value..third.end.value]);
    try std.testing.expect(it.next() == null);
}

test "cluster widths use the terminal policy" {
    try std.testing.expectEqual(@as(usize, 1), unicode.text("e\u{301}").width());
    try std.testing.expectEqual(@as(usize, 2), unicode.text("世").width());
    try std.testing.expectEqual(@as(usize, 2), unicode.text("👩‍💻").width());
    try std.testing.expectEqual(@as(usize, 3), unicode.text("e\u{301}👩‍💻").width());
}

test "measured graphemes distinguish ignored input from replacement cells" {
    var it = unicode.text("\xffa\u{903}\u{903}").graphemes().measured().iterator();
    const ignored = it.next().?;
    try std.testing.expectEqual(@as(u2, 0), ignored.columns);
    try std.testing.expect(!ignored.renderable);
    const replacement = it.next().?;
    try std.testing.expectEqual(@as(u2, 1), replacement.columns);
    try std.testing.expect(!replacement.renderable);
    try std.testing.expect(it.next() == null);
}
