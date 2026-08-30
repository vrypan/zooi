const std = @import("std");
const posix = std.posix;

const event = @import("event.zig");
const sys = @import("sys.zig");
const screen_mod = @import("screen.zig");

const Ui = event.Ui;
const Size = event.Size;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const gpa = std.testing.allocator;

/// A Ui driven by a pipe instead of a terminal.
///
/// Built by struct literal rather than through a test-only constructor: the
/// loop is what is under test, not the lifecycle, and adding an `initForTest`
/// to the library would put a seam in the public type for no one's benefit.
/// `deinit` is never called on these — there is no terminal state to restore —
/// so the fixture closes what it opened.
const Fixture = struct {
    ui: Ui,
    write_fd: sys.Fd,
    read_fd: sys.Fd,
    wake: [2]sys.Fd,
    null_fd: sys.Fd,

    fn init(escape_timeout_ms: u16) !Fixture {
        const pipe = try sys.selfPipe();
        const wake = try sys.selfPipe();
        const null_fd = try posix.openatZ(posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0);
        const size: Size = .{ .rows = 24, .cols = 80 };

        return .{
            .ui = .{
                .term = .{
                    .in_fd = pipe[0],
                    .out_fd = null_fd,
                    .owned = null,
                    .saved = undefined,
                    .alt = false,
                    .wake = wake,
                    .prev_winch = undefined,
                },
                .scr = screen_mod.Screen.init(gpa, null_fd, size),
                .escape_timeout_ms = escape_timeout_ms,
                .last_size = size,
            },
            .write_fd = pipe[1],
            .read_fd = pipe[0],
            .wake = wake,
            .null_fd = null_fd,
        };
    }

    fn deinit(self: *Fixture) void {
        self.ui.scr.deinit();
        sys.close(self.read_fd);
        sys.close(self.write_fd);
        sys.close(self.wake[0]);
        sys.close(self.wake[1]);
        sys.close(self.null_fd);
    }

    fn send(self: *Fixture, bytes: []const u8) !void {
        try sys.writeAll(self.write_fd, bytes);
    }

    /// Simulate a SIGWINCH without raising one: the handler's only job is to
    /// make this descriptor readable.
    fn poke(self: *Fixture, times: usize) !void {
        var i: usize = 0;
        while (i < times) : (i += 1) try sys.writeAll(self.wake[1], "\x00");
    }
};

test "keys arrive from the descriptor" {
    var f = try Fixture.init(25);
    defer f.deinit();

    try f.send("abc");
    try expectEqual(@as(u21, 'a'), (try f.ui.nextEvent()).?.key.character);
    try expectEqual(@as(u21, 'b'), (try f.ui.nextEvent()).?.key.character);
    try expectEqual(@as(u21, 'c'), (try f.ui.nextEvent()).?.key.character);
}

test "several keys in one read are drained before polling again" {
    // If the loop polled between keys it would block here, because nothing
    // further is ever written.
    var f = try Fixture.init(25);
    defer f.deinit();

    try f.send("\x1b[A\x1b[B");
    try expectEqual(event.Event{ .key = .up }, (try f.ui.nextEvent()).?);
    try expectEqual(event.Event{ .key = .down }, (try f.ui.nextEvent()).?);
}

test "an input burst larger than the parser buffer loses no keys" {
    var f = try Fixture.init(25);
    defer f.deinit();

    // Twenty arrows are 60 bytes. The parser intentionally stays small and
    // inline, so the event loop must split this kernel read into chunks.
    const burst = "\x1b[B" ** 20;
    try f.send(burst);
    for (0..20) |_| {
        try expectEqual(event.Event{ .key = .down }, (try f.ui.nextEvent()).?);
    }
}

test "a lone ESC becomes Escape once the timeout expires" {
    var f = try Fixture.init(5);
    defer f.deinit();

    try f.send("\x1b");
    try expectEqual(event.Event{ .key = .escape }, (try f.ui.nextEvent()).?);
}

test "an escape sequence completing in time is not read as Escape" {
    var f = try Fixture.init(200);
    defer f.deinit();

    try f.send("\x1b[A");
    try expectEqual(event.Event{ .key = .up }, (try f.ui.nextEvent()).?);
}

test "end of stream returns null" {
    var f = try Fixture.init(25);
    defer f.deinit();

    sys.close(f.write_fd);
    f.write_fd = -1; // deinit must not close it twice
    try expect(try f.ui.nextEvent() == null);
}

test "a resize that does not change the size produces no event" {
    // The wake pipe is drained and the loop goes back to waiting, so the key
    // written afterwards is what comes out.
    var f = try Fixture.init(25);
    defer f.deinit();

    try f.poke(1);
    try f.send("x");
    try expectEqual(@as(u21, 'x'), (try f.ui.nextEvent()).?.key.character);
}

test "a burst of notifications is coalesced" {
    var f = try Fixture.init(25);
    defer f.deinit();

    try f.poke(8);
    try f.send("x");
    try expectEqual(@as(u21, 'x'), (try f.ui.nextEvent()).?.key.character);

    // Every notification was consumed: a leftover byte would wake the loop
    // again for no reason.
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, posix.read(f.wake[0], &buf));
}

test "a resize updates the screen before the event is delivered" {
    // Otherwise the application's next render clips to the old width for one
    // visibly wrong frame. A pipe reports no size, so the terminal falls back
    // to 24x80; starting from something else makes that a change.
    var f = try Fixture.init(25);
    defer f.deinit();

    f.ui.last_size = .{ .rows = 1, .cols = 1 };
    f.ui.scr.size = .{ .rows = 1, .cols = 1 };

    try f.poke(1);
    const ev = (try f.ui.nextEvent()).?;

    try expectEqual(@as(u16, 24), ev.resize.rows);
    try expectEqual(@as(u16, 80), ev.resize.cols);
    // The screen already knows, before the application sees the event.
    try expectEqual(@as(u16, 80), f.ui.scr.size.cols);
    try expectEqual(@as(u16, 80), f.ui.size().cols);
}

test "a partial sequence split across reads still resolves" {
    var f = try Fixture.init(200);
    defer f.deinit();

    try f.send("\x1b");
    try f.send("[");
    try f.send("A");
    try expectEqual(event.Event{ .key = .up }, (try f.ui.nextEvent()).?);
}
