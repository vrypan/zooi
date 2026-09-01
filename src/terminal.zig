//! Terminal lifecycle: raw mode, the alternate screen, size, and resize
//! notification.
//!
//! ## Two descriptors
//!
//! Input and output are tracked separately, and the input one is always an
//! inherited descriptor when there is a terminal among 0/1/2. This is forced
//! by a macOS defect: `poll()` returns `POLLNVAL` for a freshly-opened
//! `/dev/tty` — measured, with `tcgetattr` succeeding on the very same
//! descriptor — while polling an inherited tty works. Linux polls either
//! happily. Opening `/dev/tty` for the *output* side is still right and still
//! safe, because output is never polled.
//!
//! The split also preserves what `/dev/tty` was for: `prog | head` reads keys
//! from the terminal rather than the pipe, and paints to the terminal rather
//! than into the pipe.
//!
//! Restoration is a correctness requirement, not a cosmetic one. A bug here
//! leaves the user's shell in raw mode with no echo, which they can only fix
//! by typing `reset` blind. Every step of `init` is undone by the errdefer of
//! every step before it, and `deinit` runs every step unconditionally — a
//! failure to leave the alternate screen must not prevent the attempt to
//! restore termios.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const Size = @import("event.zig").Size;

pub const Fd = sys.Fd;

pub const Error = error{
    NotATerminal,
    TerminalSetupFailed,
};

pub const Options = struct {
    /// Override the descriptor. Null opens /dev/tty.
    tty: ?Fd = null,
    alternate_screen: bool = true,
    synchronized_output: bool = true,
};

const enter_alt = "\x1b[?1049h";
const leave_alt = "\x1b[?1049l";
const hide_cursor = "\x1b[?25l";
const show_cursor = "\x1b[?25h";
const end_sync = "\x1b[?2026l";
const reset_sgr = "\x1b[0m";
const clear_all = "\x1b[2J\x1b[H";

/// Process-global so `restore()` can work from a panic or signal handler,
/// where there is no `Terminal` in hand. Only one `Ui` is expected at a time.
var global: ?Saved = null;

const Saved = struct {
    in_fd: Fd,
    out_fd: Fd,
    term: posix.termios,
    alt: bool,
    sync: bool,
};

/// Restore the terminal from a panic handler or a fatal-signal handler.
///
/// Allocation-free and made of nothing but syscalls, so it is safe to call
/// from a signal handler. A no-op when no terminal is active.
///
/// zooi does not install panic or signal handlers itself: choosing a
/// process-wide signal policy is not a library's decision to make.
pub fn restore() void {
    const s = global orelse return;
    if (s.alt) {
        if (s.sync)
            sys.writeAll(s.out_fd, end_sync ++ show_cursor ++ leave_alt ++ reset_sgr) catch {}
        else
            sys.writeAll(s.out_fd, show_cursor ++ leave_alt ++ reset_sgr) catch {};
    } else {
        if (s.sync)
            sys.writeAll(s.out_fd, end_sync ++ show_cursor ++ reset_sgr) catch {}
        else
            sys.writeAll(s.out_fd, show_cursor ++ reset_sgr) catch {};
    }
    // DRAIN so the last frame is transmitted under the settings it was
    // written for, and queued typeahead survives for the next program.
    posix.tcsetattr(s.in_fd, .DRAIN, s.term) catch {};
}

pub const Terminal = struct {
    /// Polled and put into raw mode. Always an inherited descriptor when one
    /// is a terminal; see the macOS note above.
    in_fd: Fd,
    /// Written to. May be an owned /dev/tty.
    out_fd: Fd,
    /// The /dev/tty we opened, if any, so deinit can close exactly that.
    owned: ?Fd,
    saved: posix.termios,
    alt: bool,
    sync: bool = true,
    wake: [2]Fd,
    prev_winch: posix.Sigaction,
    /// The restore state and wake descriptor this terminal displaced, put back
    /// by `deinit` for the same reason `prev_winch` is: only one `Ui` is
    /// expected at a time, but clearing the globals unconditionally would
    /// leave an outer terminal unrestorable if there ever were two.
    prev_global: ?Saved = null,
    prev_wake_fd: Fd = -1,

    pub fn init(options: Options) Error!Terminal {
        const prev_global = global;
        const prev_wake_fd = wake_fd;

        const acquired = try acquire(options.tty);
        errdefer if (acquired.owned) |fd| sys.close(fd);
        const fd = acquired.in_fd;
        const out = acquired.out_fd;

        // Before any change, so there is always something to restore to.
        const saved = posix.tcgetattr(fd) catch return error.NotATerminal;
        errdefer posix.tcsetattr(fd, .DRAIN, saved) catch {};

        // NOW rather than FLUSH: flushing would discard anything the user
        // typed before the interface finished starting.
        posix.tcsetattr(fd, .NOW, rawFrom(saved)) catch return error.TerminalSetupFailed;

        const wake = sys.selfPipe() catch return error.TerminalSetupFailed;
        errdefer {
            sys.close(wake[0]);
            sys.close(wake[1]);
        }

        var prev: posix.Sigaction = undefined;
        wake_fd = wake[1];
        posix.sigaction(posix.SIG.WINCH, &.{
            .handler = .{ .handler = onWinch },
            .mask = posix.sigemptyset(),
            // Harmless: the wakeup is the pipe becoming readable, not poll
            // returning EINTR, so restarting poll changes nothing.
            .flags = posix.SA.RESTART,
        }, &prev);
        errdefer {
            wake_fd = prev_wake_fd;
            posix.sigaction(posix.SIG.WINCH, &prev, null);
        }

        if (options.alternate_screen) {
            sys.writeAll(out, enter_alt ++ hide_cursor ++ clear_all) catch
                return error.TerminalSetupFailed;
        } else {
            sys.writeAll(out, hide_cursor) catch return error.TerminalSetupFailed;
        }

        global = .{
            .in_fd = fd,
            .out_fd = out,
            .term = saved,
            .alt = options.alternate_screen,
            .sync = options.synchronized_output,
        };

        return .{
            .in_fd = fd,
            .out_fd = out,
            .owned = acquired.owned,
            .saved = saved,
            .alt = options.alternate_screen,
            .sync = options.synchronized_output,
            .wake = wake,
            .prev_winch = prev,
            .prev_global = prev_global,
            .prev_wake_fd = prev_wake_fd,
        };
    }

    /// Every step runs, and every step swallows its own error: one failure
    /// must not skip the ones after it.
    pub fn deinit(self: *Terminal) void {
        if (self.alt) {
            if (self.sync)
                sys.writeAll(self.out_fd, end_sync ++ show_cursor ++ leave_alt ++ reset_sgr) catch {}
            else
                sys.writeAll(self.out_fd, show_cursor ++ leave_alt ++ reset_sgr) catch {};
        } else {
            if (self.sync)
                sys.writeAll(self.out_fd, end_sync ++ show_cursor ++ reset_sgr) catch {}
            else
                sys.writeAll(self.out_fd, show_cursor ++ reset_sgr) catch {};
        }
        posix.tcsetattr(self.in_fd, .DRAIN, self.saved) catch {};

        wake_fd = self.prev_wake_fd;
        posix.sigaction(posix.SIG.WINCH, &self.prev_winch, null);
        sys.close(self.wake[0]);
        sys.close(self.wake[1]);

        global = self.prev_global;
        if (self.owned) |fd| sys.close(fd);
    }

    /// Current dimensions. Zero rows or columns is a legitimate answer that
    /// some ptys really give; callers clip rather than assume a minimum. Only
    /// an outright ioctl failure falls back, and to a usable guess rather than
    /// an error, because a wrong size still renders something.
    pub fn size(self: *const Terminal) Size {
        const ws = sys.winsize(self.out_fd) catch return .{ .rows = 24, .cols = 80 };
        return .{ .rows = ws.row, .cols = ws.col };
    }

    /// The descriptor the event loop polls for resize notifications.
    pub fn wakeFd(self: *const Terminal) Fd {
        return self.wake[0];
    }

    /// Drain every pending notification. Several signals during a window drag
    /// collapse into one wakeup and one size query.
    pub fn drainWake(self: *const Terminal) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = posix.read(self.wake[0], &buf) catch return;
            if (n == 0) return;
        }
    }
};

const Acquired = struct { in_fd: Fd, out_fd: Fd, owned: ?Fd };

fn acquire(override: ?Fd) Error!Acquired {
    if (override) |fd| {
        if (!sys.isTty(fd)) return error.NotATerminal;
        return .{ .in_fd = fd, .out_fd = fd, .owned = null };
    }

    var owned: ?Fd = null;
    errdefer if (owned) |fd| sys.close(fd);

    // Opened at most once and shared by both sides.
    const devTty = struct {
        fn get(slot: *?Fd) ?Fd {
            if (slot.*) |fd| return fd;
            const fd = sys.openTty() catch return null;
            if (!sys.isTty(fd)) {
                sys.close(fd);
                return null;
            }
            slot.* = fd;
            return fd;
        }
    }.get;

    // Input must be an inherited descriptor where possible: poll() rejects
    // /dev/tty on macOS.
    const in_fd = if (sys.isTty(0)) @as(Fd, 0) else if (sys.isTty(2))
        @as(Fd, 2)
    else
        devTty(&owned) orelse return error.NotATerminal;

    // Output prefers stdout, then stderr, then /dev/tty. Never the pipe.
    const out_fd = if (sys.isTty(1)) @as(Fd, 1) else if (sys.isTty(2))
        @as(Fd, 2)
    else
        devTty(&owned) orelse return error.NotATerminal;

    return .{ .in_fd = in_fd, .out_fd = out_fd, .owned = owned };
}

fn rawFrom(saved: posix.termios) posix.termios {
    var raw = saved;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;

    raw.oflag.OPOST = false;

    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    // Ctrl-C reaches the parser as a key instead of killing the process. The
    // application decides what it means, and therefore owns quitting.
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.cflag.PARENB = false;
    raw.cflag.CSIZE = .CS8;

    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    return raw;
}

var wake_fd: Fd = -1;

/// Does one thing: wakes the loop. No ioctl, no allocation, no rendering —
/// the loop reads the new size itself once it is awake.
fn onWinch(_: posix.SIG) callconv(.c) void {
    if (wake_fd < 0) return;
    const byte = [_]u8{0};
    if (sys.via_libc) {
        // libc's write sets errno; a handler must leave it as it found it.
        const saved = std.c._errno().*;
        _ = posix.system.write(wake_fd, &byte, 1);
        std.c._errno().* = saved;
    } else {
        _ = posix.system.write(wake_fd, &byte, 1);
    }
}
