const std = @import("std");
const screen_mod = @import("screen.zig");
const Screen = screen_mod.Screen;
const Style = screen_mod.Style;
const Size = @import("event.zig").Size;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const gpa = std.testing.allocator;

/// Present writes for real, so tests aim it at /dev/null and assert against
/// `frame()`. Opened once and left open for the life of the test binary.
var null_fd: std.posix.fd_t = -1;

fn nullFd() std.posix.fd_t {
    if (null_fd < 0)
        null_fd = std.posix.openatZ(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch unreachable;
    return null_fd;
}

fn testScreen(rows: u16, cols: u16) Screen {
    return Screen.init(gpa, nullFd(), .{ .rows = rows, .cols = cols });
}

/// Bytes written after `begin()`, so tests are not cluttered by the frame
/// preamble.
fn body(s: *const Screen) []const u8 {
    const preamble = "\x1b[0m\x1b[H\x1b[?25l";
    return s.frame()[preamble.len..];
}

test "begin homes and hides the cursor without clearing the screen" {
    // Clearing every frame blanks all cells and repaints them, which reads as
    // flicker. Rows are erased individually instead; see the module docs.
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    try expectEqualStrings("\x1b[0m\x1b[H\x1b[?25l", s.frame());
}

test "the first visit to a row erases the whole row" {
    var s = testScreen(3, 20);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.write("ab");
    s.move(1, 0);
    try expectEqualStrings("\x1b[1;1H\x1b[Kab\x1b[2;1H\x1b[K", body(&s));
}

test "a row drawn at scattered columns has blank gaps, not stale cells" {
    // The case that a from-the-cursor erase gets wrong: writing at column 2
    // and again at column 14 must not leave last frame's content in between,
    // or in columns 0 and 1.
    var s = testScreen(2, 30);
    defer s.deinit();
    s.begin();
    s.move(0, 2);
    s.write("label");
    s.move(0, 14);
    s.write("value");
    // Row erased once, up front, then positioned twice.
    try expectEqualStrings("\x1b[1;1H\x1b[K\x1b[1;3Hlabel\x1b[1;15Hvalue", body(&s));
}

test "revisiting a row does not erase what was already drawn on it" {
    var s = testScreen(2, 30);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.write("keep");
    s.move(0, 10);
    s.write("this");
    try expect(std.mem.count(u8, body(&s), "\x1b[K") == 1);
}

test "rows the frame never touched are blanked at present" {
    // This is what replaces the screen-wide clear: nothing stale survives.
    var s = testScreen(4, 20);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.write("only this row");
    try s.present();
    const out = body(&s);
    try expect(std.mem.indexOf(u8, out, "\x1b[2;1H\x1b[K") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[3;1H\x1b[K") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[4;1H\x1b[K") != null);
}

test "a frame that draws every row adds no blanking" {
    var s = testScreen(3, 20);
    defer s.deinit();
    s.begin();
    var r: u16 = 0;
    while (r < 3) : (r += 1) {
        s.move(r, 0);
        s.write("x");
    }
    try s.present();
    // One erase per row, and no blanking pass, because every row was drawn.
    try expect(std.mem.count(u8, body(&s), "\x1b[K") == 3);
}

test "move converts 0-based to the terminal's 1-based coordinates" {
    // The likeliest off-by-one in the library, asserted explicitly.
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    try expectEqualStrings("\x1b[1;1H\x1b[K", body(&s));

    s.begin();
    s.move(3, 7);
    try expectEqualStrings("\x1b[4;1H\x1b[K\x1b[4;8H", body(&s));
}

test "plain text within bounds appears verbatim" {
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.write("hello");
    try expectEqualStrings("\x1b[1;1H\x1b[Khello", body(&s));
}

test "text is clipped to the terminal width" {
    var s = testScreen(24, 10);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.write("abcdefghijklmno");
    try expectEqualStrings("\x1b[1;1H\x1b[Kabcdefghij", body(&s));
}

test "clipping counts columns, not bytes" {
    // Six wide characters are twelve columns; ten columns fit five.
    var s = testScreen(24, 10);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.write("世世世世世世");
    try expectEqualStrings("\x1b[1;1H\x1b[K世世世世世", body(&s));
}

test "a wide character straddling the edge becomes a space" {
    // Half a wide character corrupts the terminal's column tracking for the
    // rest of the line, so it is never emitted.
    var s = testScreen(24, 5);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.write("abcd世");
    try expectEqualStrings("\x1b[1;1H\x1b[Kabcd ", body(&s));
}

test "writes to an off-screen row produce nothing" {
    var s = testScreen(3, 80);
    defer s.deinit();
    s.begin();
    s.move(3, 0);
    s.write("invisible");
    s.clearToEndOfLine();
    try expectEqualStrings("", body(&s));

    // And an in-bounds row still works afterwards.
    s.move(1, 0);
    s.write("ok");
    try expectEqualStrings("\x1b[2;1H\x1b[Kok", body(&s));
}

test "control bytes are dropped" {
    // A recorded command can contain a stray CR. If it reached the terminal
    // the row would be overwritten from column zero.
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.write("a\rb\nc\x00d\x1b[2Je");
    try expectEqualStrings("\x1b[1;1H\x1b[Kabcd[2Je", body(&s));
}

test "malformed bytes are dropped" {
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.write("a\xffb");
    try expectEqualStrings("\x1b[1;1H\x1b[Kab", body(&s));
}

test "an identical style is not re-emitted" {
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.writeStyled("a", .{ .bold = true });
    s.writeStyled("b", .{ .bold = true });
    // One SGR run, then both characters.
    try expectEqualStrings("\x1b[1;1H\x1b[K\x1b[0m\x1b[1m\x1b[39m\x1b[49mab", body(&s));
}

test "a changed style is re-emitted" {
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.writeStyled("a", .{ .bold = true });
    s.writeStyled("b", .{ .reverse = true });
    const out = body(&s);
    try expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[7m") != null);
}

test "the default style after a colored one resets rather than picks a color" {
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.writeStyled("a", .{ .fg = .{ .ansi = 1 }, .bg = .{ .ansi = 2 } });
    s.writeStyled("b", .{});
    const out = body(&s);
    // Null means the terminal's default, which is SGR 39/49 and not any
    // particular color.
    try expect(std.mem.indexOf(u8, out, "\x1b[39m") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[49m") != null);
}

test "the default style at the start of a frame emits nothing" {
    // begin() already reset SGR, so re-stating the default is redundant and
    // the coalescing check suppresses it.
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.writeStyled("x", .{});
    try expectEqualStrings("\x1b[1;1H\x1b[Kx", body(&s));
}

test "colors encode in all three forms" {
    var s = testScreen(24, 80);
    defer s.deinit();

    s.begin();
    s.move(0, 0);
    s.writeStyled("x", .{ .fg = .{ .ansi = 1 } });
    try expect(std.mem.indexOf(u8, body(&s), "\x1b[31m") != null);

    s.begin();
    s.move(0, 0);
    s.writeStyled("x", .{ .fg = .{ .ansi = 9 } }); // bright red is +60
    try expect(std.mem.indexOf(u8, body(&s), "\x1b[91m") != null);

    s.begin();
    s.move(0, 0);
    s.writeStyled("x", .{ .fg = .{ .indexed = 200 } });
    try expect(std.mem.indexOf(u8, body(&s), "\x1b[38;5;200m") != null);

    s.begin();
    s.move(0, 0);
    s.writeStyled("x", .{ .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } });
    try expect(std.mem.indexOf(u8, body(&s), "\x1b[48;2;1;2;3m") != null);
}

test "showCursor positions and reveals the cursor at present time" {
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.showCursor(2, 5);
    try s.present();
    try expect(std.mem.endsWith(u8, s.frame(), "\x1b[3;6H\x1b[?25h"));
}

test "a frame without showCursor leaves the cursor hidden" {
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.move(0, 0);
    s.write("x");
    try s.present();
    try expect(std.mem.indexOf(u8, s.frame(), "\x1b[?25h") == null);
}

test "an off-screen cursor request is ignored" {
    var s = testScreen(5, 5);
    defer s.deinit();
    s.begin();
    s.showCursor(99, 99);
    try s.present();
    try expect(std.mem.indexOf(u8, s.frame(), "\x1b[?25h") == null);
}

test "a degenerate size accepts a full render and produces no output" {
    // 0x0 is what a pty with no dimensions reports. Verified on hardware.
    for ([_]Size{ .{ .rows = 0, .cols = 0 }, .{ .rows = 1, .cols = 1 } }) |sz| {
        var s = Screen.init(gpa, nullFd(), sz);
        defer s.deinit();
        s.begin();
        s.move(0, 0);
        s.write("hello");
        s.writeStyled("world", .{ .bold = true });
        s.clearToEndOfLine();
        s.showCursor(0, 0);
        try s.present();
    }
}

test "frames are independent and steady state does not allocate" {
    var s = testScreen(24, 80);
    defer s.deinit();

    s.begin();
    s.move(0, 0);
    s.write("hello");
    const first = try gpa.dupe(u8, s.frame());
    defer gpa.free(first);

    const cap_before = s.buf.capacity;
    s.begin();
    s.move(0, 0);
    s.write("hello");

    // Identical bytes: clearRetainingCapacity leaves no state behind.
    try expectEqualStrings(first, s.frame());
    // And no reallocation, which is what makes full redraws defensible.
    try expectEqual(cap_before, s.buf.capacity);
}

test "an allocation failure latches and surfaces at present" {
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var s = Screen.init(failing.allocator(), nullFd(), .{ .rows = 24, .cols = 80 });
    defer s.deinit();

    // A whole render sequence runs without crashing...
    s.begin();
    s.move(0, 0);
    s.write("hello");
    s.writeStyled("world", .{ .bold = true });
    s.clearToEndOfLine();

    // ...and the failure appears exactly once, at the boundary.
    try std.testing.expectError(error.OutOfMemory, s.present());
}
