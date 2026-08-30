const std = @import("std");
const screen_mod = @import("screen.zig");
const sys = @import("sys.zig");
const Screen = screen_mod.Screen;
const Style = screen_mod.Style;
const Size = @import("event.zig").Size;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const gpa = std.testing.allocator;

const begin_sync = "\x1b[?2026h";
const end_sync = "\x1b[?2026l";
const draw_preamble = "\x1b[0m\x1b[H\x1b[?25l";
const preamble = begin_sync ++ draw_preamble;

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

fn body(s: *const Screen) []const u8 {
    return s.frame()[preamble.len..];
}

test "begin prepares a retained frame without painting cells" {
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.move(3, 7);
    s.write("hello");
    try expectEqualStrings(preamble, s.frame());
}

test "present wraps output in synchronized-update mode" {
    var s = testScreen(2, 20);
    defer s.deinit();
    s.begin();
    s.write("frame");
    try s.present();
    try expect(std.mem.startsWith(u8, s.frame(), begin_sync));
    try expect(std.mem.endsWith(u8, s.frame(), end_sync));
}

test "synchronized output can be disabled" {
    var s = testScreen(2, 20);
    defer s.deinit();
    s.setSynchronizedOutput(false);
    s.begin();
    s.write("frame");
    try expectEqualStrings(draw_preamble, s.frame());
    try s.present();
    try expect(std.mem.indexOf(u8, s.frame(), "?2026") == null);
}

test "the first frame clears once and paints only populated spans" {
    var s = testScreen(3, 20);
    defer s.deinit();
    s.begin();
    s.move(0, 2);
    s.write("label");
    s.move(0, 14);
    s.write("value");
    s.move(1, 0);
    s.write("second");
    try s.present();

    const out = body(&s);
    try expect(std.mem.startsWith(u8, out, "\x1b[2J"));
    try expect(std.mem.indexOf(u8, out, "\x1b[1;3Hlabel       value") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[2;1Hsecond") != null);
    // Empty row 3 was covered by the one-time clear, not repainted.
    try expect(std.mem.indexOf(u8, out, "\x1b[3;") == null);
}

test "an identical second frame emits no cell updates" {
    var s = testScreen(3, 20);
    defer s.deinit();

    s.begin();
    s.move(1, 4);
    s.write("same");
    try s.present();

    s.begin();
    s.move(1, 4);
    s.write("same");
    try s.present();
    try expectEqualStrings(preamble ++ end_sync, s.frame());
}

test "changing cursor style damages only the old and new rows" {
    const cursor: Style = .{ .reverse = true };
    var s = testScreen(4, 30);
    defer s.deinit();

    const draw = struct {
        fn frame(screen: *Screen, selected: usize) void {
            screen.begin();
            for ([_][]const u8{ "alpha", "beta", "gamma", "delta" }, 0..) |text, row| {
                screen.move(@intCast(row), 0);
                screen.writeStyled(text, if (row == selected) cursor else .{});
            }
        }
    }.frame;

    draw(&s, 0);
    try s.present();
    draw(&s, 1);
    try s.present();

    const out = body(&s);
    try expect(std.mem.indexOf(u8, out, "\x1b[1;1H") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[2;1H") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[3;1H") == null);
    try expect(std.mem.indexOf(u8, out, "\x1b[4;1H") == null);
    try expect(std.mem.indexOf(u8, out, "alpha") != null);
    try expect(std.mem.indexOf(u8, out, "beta") != null);
    try expect(std.mem.indexOf(u8, out, "gamma") == null);
    try expect(std.mem.indexOf(u8, out, "delta") == null);
}

test "shortening or removing content clears the old tail" {
    var s = testScreen(2, 20);
    defer s.deinit();

    s.begin();
    s.write("a long first value");
    s.move(1, 0);
    s.write("remove me");
    try s.present();

    s.begin();
    s.write("short");
    try s.present();
    const out = body(&s);
    try expect(std.mem.indexOf(u8, out, "\x1b[1;1Hshort\x1b[K") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[2;1H\x1b[K") != null);
}

test "erasing a styled tail resets its background first" {
    var s = testScreen(2, 20);
    defer s.deinit();

    s.begin();
    s.write("old first");
    s.move(1, 0);
    s.writeStyled("colored tail", .{ .reverse = true });
    try s.present();

    s.begin();
    // Row 0 changes to a styled value, leaving reverse active immediately
    // before the removed second row is erased.
    s.writeStyled("new first", .{ .reverse = true });
    try s.present();
    const out = body(&s);
    const row_two = std.mem.indexOf(u8, out, "\x1b[2;1H") orelse return error.TestUnexpectedResult;
    const reset = std.mem.indexOfPos(u8, out, row_two, "\x1b[0m") orelse return error.TestUnexpectedResult;
    const erase = std.mem.indexOfPos(u8, out, row_two, "\x1b[K") orelse return error.TestUnexpectedResult;
    try expect(reset < erase);
}

test "move is 0-based and changed spans use 1-based ANSI coordinates" {
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.move(3, 7);
    s.write("x");
    try s.present();
    try expect(std.mem.indexOf(u8, body(&s), "\x1b[4;8Hx") != null);
}

test "text is clipped to the terminal width" {
    var s = testScreen(2, 10);
    defer s.deinit();
    s.begin();
    s.write("abcdefghijklmno");
    try s.present();
    try expect(std.mem.indexOf(u8, body(&s), "abcdefghij") != null);
    try expect(std.mem.indexOf(u8, body(&s), "k") == null);
}

test "clipping counts columns rather than bytes" {
    var s = testScreen(2, 10);
    defer s.deinit();
    s.begin();
    s.write("世世世世世世");
    try s.present();
    try expect(std.mem.indexOf(u8, body(&s), "世世世世世") != null);
    try expect(std.mem.count(u8, body(&s), "世") == 5);
}

test "a wide character straddling the edge becomes a space" {
    var s = testScreen(2, 5);
    defer s.deinit();
    s.begin();
    s.write("abcd世");
    try s.present();
    try expect(std.mem.indexOf(u8, body(&s), "abcd ") != null);
    try expect(std.mem.indexOf(u8, body(&s), "世") == null);
}

test "overwriting either half of a wide cell clears the whole old glyph" {
    var s = testScreen(2, 8);
    defer s.deinit();

    s.begin();
    s.write("a世z");
    try s.present();

    s.begin();
    s.write("a世z");
    s.move(0, 2); // the continuation column of 世
    s.write("x");
    try s.present();
    const out = body(&s);
    try expect(std.mem.indexOf(u8, out, "\x1b[1;2H x") != null);
    try expect(std.mem.indexOf(u8, out, "世") == null);
}

test "combining marks are retained with their base cell" {
    var s = testScreen(2, 10);
    defer s.deinit();

    s.begin();
    s.write("cafe\u{301}");
    try s.present();
    try expect(std.mem.indexOf(u8, body(&s), "cafe\u{301}") != null);

    s.begin();
    s.write("cafe\u{301}");
    try s.present();
    try expectEqualStrings(preamble ++ end_sync, s.frame());
}

test "writes to an off-screen row produce no cells" {
    var s = testScreen(3, 80);
    defer s.deinit();
    s.begin();
    s.move(3, 0);
    s.write("invisible");
    s.clearToEndOfLine();
    s.move(1, 0);
    s.write("ok");
    try s.present();
    try expect(std.mem.indexOf(u8, body(&s), "invisible") == null);
    try expect(std.mem.indexOf(u8, body(&s), "\x1b[2;1Hok") != null);
}

test "control and malformed bytes are dropped" {
    var s = testScreen(2, 80);
    defer s.deinit();
    s.begin();
    s.write("a\rb\nc\x00d\x1b[2Je\xfff");
    try s.present();
    try expect(std.mem.indexOf(u8, body(&s), "abcd[2Jef") != null);
}

test "identical adjacent styles emit one SGR run" {
    var s = testScreen(2, 20);
    defer s.deinit();
    s.begin();
    s.writeStyled("a", .{ .bold = true });
    s.writeStyled("b", .{ .bold = true });
    try s.present();
    const out = body(&s);
    try expect(std.mem.count(u8, out, "\x1b[1m") == 1);
    try expect(std.mem.indexOf(u8, out, "ab") != null);
}

test "styled space runs stay literal by default, at any length" {
    // The default path has to emit runs of arbitrary length correctly. Before
    // REP became opt-in nothing longer than five spaces could reach it.
    for ([_]u16{ 1, 31, 32, 33, 64, 65, 200 }) |run| {
        var s = Screen.init(gpa, nullFd(), .{ .rows = 1, .cols = run });
        defer s.deinit();
        s.begin();
        var i: u16 = 0;
        while (i < run) : (i += 1) s.writeStyled(" ", .{ .reverse = true });
        try s.present();
        const out = body(&s);
        try expectEqual(@as(usize, run), std.mem.count(u8, out, " "));
        try expect(std.mem.indexOf(u8, out, "b") == null);
    }
}

test "long styled space runs use REP when it is enabled" {
    var s = testScreen(2, 40);
    defer s.deinit();
    s.setRepeatSequences(true);
    s.begin();
    s.writeStyled("                    ", .{ .reverse = true });
    try s.present();
    const out = body(&s);
    try expect(std.mem.indexOf(u8, out, " \x1b[19b") != null);
    try expect(std.mem.count(u8, out, "\x1b[7m") == 1);
}

test "short space runs stay literal" {
    var s = testScreen(2, 20);
    defer s.deinit();
    s.begin();
    s.writeStyled("    x", .{ .reverse = true });
    try s.present();
    const out = body(&s);
    try expect(std.mem.indexOf(u8, out, "    x") != null);
    try expect(std.mem.indexOf(u8, out, "b") == null);
}

test "changed styles and all color forms are encoded" {
    var s = testScreen(2, 20);
    defer s.deinit();
    s.begin();
    s.writeStyled("a", .{ .fg = .{ .ansi = 1 } });
    s.writeStyled("b", .{ .fg = .{ .ansi = 9 } });
    s.writeStyled("c", .{ .fg = .{ .indexed = 200 } });
    s.writeStyled("d", .{ .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } });
    s.writeStyled("e", .{});
    try s.present();
    const out = body(&s);
    try expect(std.mem.indexOf(u8, out, "\x1b[31m") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[91m") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[38;5;200m") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[48;2;1;2;3m") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[39m") != null);
    try expect(std.mem.indexOf(u8, out, "\x1b[49m") != null);
}

test "showCursor positions and reveals the cursor at present time" {
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.showCursor(2, 5);
    try s.present();
    try expect(std.mem.endsWith(u8, s.frame(), "\x1b[3;6H\x1b[?25h" ++ end_sync));
}

test "a frame without showCursor leaves the cursor hidden" {
    var s = testScreen(24, 80);
    defer s.deinit();
    s.begin();
    s.write("x");
    try s.present();
    try expect(std.mem.indexOf(u8, body(&s), "\x1b[?25h") == null);
}

test "an off-screen cursor request is ignored" {
    var s = testScreen(5, 5);
    defer s.deinit();
    s.begin();
    s.showCursor(99, 99);
    try s.present();
    try expect(std.mem.indexOf(u8, body(&s), "\x1b[?25h") == null);
}

test "resize invalidates coordinates and repaints from a clear screen" {
    var s = testScreen(2, 10);
    defer s.deinit();
    s.begin();
    s.write("before");
    try s.present();

    s.size = .{ .rows = 3, .cols = 12 };
    s.begin();
    s.write("after");
    try s.present();
    try expect(std.mem.startsWith(u8, body(&s), "\x1b[2J"));
    try expect(std.mem.indexOf(u8, body(&s), "after") != null);
}

test "degenerate sizes accept a complete render" {
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

test "steady-state frames reuse grid, text, and output allocations" {
    var s = testScreen(24, 80);
    defer s.deinit();

    s.begin();
    s.move(0, 0);
    s.write("hello");
    try s.present();

    // The second frame allocates the other half of the double buffer.
    s.begin();
    s.move(0, 0);
    s.write("hello");
    try s.present();
    const capacities = .{
        s.buf.capacity,
        s.front.capacity,
        s.back.capacity,
        s.front_text.capacity,
        s.back_text.capacity,
    };

    s.begin();
    s.move(0, 0);
    s.write("hello");
    try s.present();
    try expectEqual(capacities[0], s.buf.capacity);
    try expectEqual(capacities[1], s.front.capacity);
    try expectEqual(capacities[2], s.back.capacity);
    try expectEqual(capacities[3], s.front_text.capacity);
    try expectEqual(capacities[4], s.back_text.capacity);
}

test "an allocation failure latches and surfaces at present" {
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var s = Screen.init(failing.allocator(), nullFd(), .{ .rows = 24, .cols = 80 });
    defer s.deinit();

    s.begin();
    s.write("hello");
    s.writeStyled("world", .{ .bold = true });
    s.clearToEndOfLine();
    try std.testing.expectError(error.OutOfMemory, s.present());
}

test "a failed present gives up the diff baseline instead of corrupting it" {
    // A failed write leaves the terminal showing neither the old frame nor the
    // whole new one. Diffing the next frame against a grid the terminal never
    // reached would corrupt every frame after it, so the baseline is dropped
    // and the next present repaints in full.
    const p = try sys.selfPipe();
    defer sys.close(p[1]);

    var s = Screen.init(gpa, p[1], .{ .rows = 1, .cols = 8 });
    defer s.deinit();

    s.begin();
    s.write("hi");
    try s.present();
    try expect(s.front_valid);

    // With no reader left, the next write fails outright.
    sys.close(p[0]);
    s.begin();
    s.write("bye");
    try std.testing.expectError(error.WriteFailed, s.present());
    try expect(!s.front_valid);
}
