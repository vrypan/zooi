//! The handful of syscalls `std.posix` no longer wraps in Zig 0.16.
//!
//! `std.posix` has `read`, `poll`, `sigaction`, `tcgetattr`, `tcsetattr`, and
//! `openatZ`, but no `write`, `close`, `open`, `pipe`, `pipe2`, or `ioctl` —
//! most file I/O moved behind `std.Io`, where every call takes an `Io`
//! instance. zooi is deliberately synchronous and blocking, so it works at the
//! descriptor level instead and supplies the missing six here.
//!
//! Two axes are at play and they are kept apart:
//!
//!   * **libc vs raw syscall.** `std.posix.system` already resolves this: it
//!     is `std.c` when the program links libc and `std.os.linux` when it does
//!     not. Routing through it means zooi follows whatever the consumer's
//!     build chose rather than overriding it — a consumer linking libc for its
//!     own reasons gets the libc path, and a libc-free build gets raw
//!     syscalls.
//!   * **Linux vs Darwin API shape.** Only `pipe` and `ioctl` genuinely
//!     differ, and both branch on which backend `system` resolved to, never on
//!     the OS.
//!
//! `posix.errno` is likewise `system.errno`, so it decodes whichever return
//! convention is active: a negative-encoded `usize` from a raw syscall, or
//! `-1` plus thread-local `errno` from libc.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Fd = posix.fd_t;

/// True when std.posix routes through libc. Not the same question as "is this
/// macOS": a Linux consumer that links libc lands here too.
pub const via_libc = posix.system == std.c;

fn ok(rc: anytype) bool {
    return posix.errno(rc) == .SUCCESS;
}

pub fn close(fd: Fd) void {
    _ = posix.system.close(fd);
}

pub fn write(fd: Fd, bytes: []const u8) error{WriteFailed}!usize {
    while (true) {
        const rc = posix.system.write(fd, bytes.ptr, bytes.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            // O_NONBLOCK belongs to the open file description, which is shared
            // and inherited, so an ancestor process can leave it set on the
            // terminal without zooi ever asking for it. Waiting for writability
            // gives back the blocking semantics the rest of the library assumes
            // instead of failing a frame because the terminal fell behind.
            .AGAIN => if (waitWritable(fd)) continue else return error.WriteFailed,
            else => return error.WriteFailed,
        }
    }
}

/// Block until `fd` accepts more bytes. False means it never will.
///
/// `poll` is on POSIX's async-signal-safe list, so this keeps `restore()`
/// callable from a signal handler.
fn waitWritable(fd: Fd) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
    _ = posix.poll(&fds, -1) catch return false;
    return fds[0].revents & posix.POLL.OUT != 0;
}

pub fn writeAll(fd: Fd, bytes: []const u8) error{WriteFailed}!void {
    var off: usize = 0;
    while (off < bytes.len) off += try write(fd, bytes[off..]);
}

/// A pipe a signal handler can write to in order to wake the event loop.
///
/// Both ends are non-blocking, because a handler that blocked on a full pipe
/// would deadlock the loop it exists to wake, and close-on-exec, so the
/// descriptors never leak into whatever the application spawns.
pub fn selfPipe() error{PipeFailed}![2]Fd {
    var fds: [2]Fd = undefined;
    const has_pipe2 = @hasDecl(posix.system, "pipe2") and
        @TypeOf(posix.system.pipe2) != void;

    if (has_pipe2) {
        if (!ok(posix.system.pipe2(&fds, posix.O{ .NONBLOCK = true, .CLOEXEC = true })))
            return error.PipeFailed;
        return fds;
    }

    // Darwin has no pipe2; set both flags afterwards.
    if (!ok(posix.system.pipe(&fds))) return error.PipeFailed;
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    for (fds) |f| {
        const fl = posix.system.fcntl(f, posix.F.GETFL, @as(c_int, 0));
        if (fl < 0) return error.PipeFailed;
        if (posix.system.fcntl(f, posix.F.SETFL, fl | nonblock) < 0) return error.PipeFailed;
        if (posix.system.fcntl(f, posix.F.SETFD, @as(c_int, 1)) < 0) return error.PipeFailed;
    }
    return fds;
}

pub fn winsize(fd: Fd) error{IoctlFailed}!posix.winsize {
    var ws: posix.winsize = undefined;
    if (via_libc) {
        // The libc prototype is variadic and takes a signed request.
        if (std.c.ioctl(fd, @as(c_int, @bitCast(@as(u32, posix.T.IOCGWINSZ))), &ws) != 0)
            return error.IoctlFailed;
    } else {
        // The raw syscall takes the argument as an integer.
        if (!ok(posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws))))
            return error.IoctlFailed;
    }
    return ws;
}

pub fn openTty() !Fd {
    return posix.openatZ(posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0);
}

/// A successful TIOCGWINSZ is the tty test. It avoids libc's `isatty` and asks
/// for the thing zooi wanted to know anyway.
pub fn isTty(fd: Fd) bool {
    _ = winsize(fd) catch return false;
    return true;
}
