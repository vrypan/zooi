//! Most of the terminal lifecycle needs a real terminal and belongs to the
//! PTY suite. What can be checked without one is checked here.
//!
//! Deliberately absent: any test that opens the test runner's own terminal.
//! It may not have one, and a failing test would leave it broken.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const terminal = @import("terminal.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "the self-pipe carries a wakeup" {
    const p = try sys.selfPipe();
    defer {
        sys.close(p[0]);
        sys.close(p[1]);
    }
    try sys.writeAll(p[1], "\x00");
    var buf: [8]u8 = undefined;
    try expectEqual(@as(usize, 1), try posix.read(p[0], &buf));
}

test "the self-pipe read end is non-blocking" {
    // A blocking read end would hang the event loop on a spurious wakeup.
    const p = try sys.selfPipe();
    defer {
        sys.close(p[0]);
        sys.close(p[1]);
    }
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, posix.read(p[0], &buf));
}

test "the self-pipe does not block the writer when data is already queued" {
    // The handler must never block: it would deadlock the loop it is waking.
    const p = try sys.selfPipe();
    defer {
        sys.close(p[0]);
        sys.close(p[1]);
    }
    var i: usize = 0;
    while (i < 16) : (i += 1) try sys.writeAll(p[1], "\x00");
}

test "the self-pipe is close-on-exec" {
    const p = try sys.selfPipe();
    defer {
        sys.close(p[0]);
        sys.close(p[1]);
    }
    const flags: i64 = if (sys.via_libc)
        @intCast(std.c.fcntl(p[0], posix.F.GETFD, @as(c_int, 0)))
    else
        @bitCast(@as(u64, posix.system.fcntl(p[0], posix.F.GETFD, @as(usize, 0))));
    try expect(flags >= 0 and (flags & 1) == 1);
}

test "a non-terminal descriptor is refused and left alone" {
    const p = try sys.selfPipe();
    defer {
        sys.close(p[0]);
        sys.close(p[1]);
    }
    try std.testing.expectError(
        error.NotATerminal,
        terminal.Terminal.init(.{ .tty = p[0] }),
    );
    // The descriptor still works: nothing was changed on the way out.
    try sys.writeAll(p[1], "x");
    var buf: [8]u8 = undefined;
    try expectEqual(@as(usize, 1), try posix.read(p[0], &buf));
}

test "isTty is false for a pipe" {
    const p = try sys.selfPipe();
    defer {
        sys.close(p[0]);
        sys.close(p[1]);
    }
    try expect(!sys.isTty(p[0]));
}

test "restore with no active terminal is a no-op" {
    // It runs from panic and signal handlers, where there may be no Ui.
    terminal.restore();
    terminal.restore();
}
