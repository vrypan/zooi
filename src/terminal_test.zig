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

test "writeAll survives a non-blocking descriptor that fills up" {
    // O_NONBLOCK is a property of the shared open file description, so a parent
    // process can leave it set on the terminal zooi inherits. A frame larger
    // than the kernel buffer then writes short with EAGAIN, and giving up there
    // would kill a working application over a slow link.
    const p = try sys.selfPipe();
    defer {
        sys.close(p[0]);
        sys.close(p[1]);
    }

    const big = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');

    // The reader stops on the flag as well as on the byte count, so a
    // regression fails this test instead of hanging it.
    var stop = std.atomic.Value(bool).init(false);
    const drain = try std.Thread.spawn(.{}, struct {
        fn run(fd: sys.Fd, total: usize, halt: *std.atomic.Value(bool)) void {
            var buf: [4096]u8 = undefined;
            var got: usize = 0;
            while (got < total and !halt.load(.acquire)) {
                const n = posix.read(fd, &buf) catch continue;
                if (n == 0) return;
                got += n;
            }
        }
    }.run, .{ p[0], big.len, &stop });
    defer {
        stop.store(true, .release);
        drain.join();
    }

    try sys.writeAll(p[1], big);
}

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
