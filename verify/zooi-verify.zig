//! zooi-verify — runtime proof that zooi's terminal primitives work on Linux
//! with no libc linked.
//!
//! Every claim in plans/README.md D8 and D14 was established at compile time on
//! a macOS host. This binary establishes them at run time. It exercises exactly
//! the syscalls src/sys.zig and src/terminal.zig will use, reports PASS/FAIL
//! per check, and exits non-zero if any check fails.
//!
//! Build:
//!   zig build-exe zooi-verify.zig -target x86_64-linux-none -O ReleaseSafe
//!
//! It needs no arguments. Run it in a terminal for the full suite; run it
//! piped or under a non-tty and the terminal-dependent checks report SKIP
//! rather than failing.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Fd = posix.fd_t;

/// True when std.posix routes through libc. On a -none build this is false and
/// every call below is a raw syscall.
const via_libc = posix.system == std.c;

// --- the sys.zig shim under test --------------------------------------------

fn ok(rc: anytype) bool {
    return posix.errno(rc) == .SUCCESS;
}

fn sysClose(fd: Fd) void {
    _ = posix.system.close(fd);
}

fn sysWrite(fd: Fd, bytes: []const u8) error{WriteFailed}!usize {
    while (true) {
        const rc = posix.system.write(fd, bytes.ptr, bytes.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn sysWriteAll(fd: Fd, bytes: []const u8) error{WriteFailed}!void {
    var off: usize = 0;
    while (off < bytes.len) off += try sysWrite(fd, bytes[off..]);
}

fn selfPipe() error{PipeFailed}![2]Fd {
    var fds: [2]Fd = undefined;
    const has_pipe2 = @hasDecl(posix.system, "pipe2") and
        @TypeOf(posix.system.pipe2) != void;

    if (has_pipe2) {
        if (!ok(posix.system.pipe2(&fds, posix.O{ .NONBLOCK = true, .CLOEXEC = true })))
            return error.PipeFailed;
        return fds;
    }

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

fn winsize(fd: Fd) error{IoctlFailed}!posix.winsize {
    var ws: posix.winsize = undefined;
    if (via_libc) {
        if (std.c.ioctl(fd, @as(c_int, @bitCast(@as(u32, posix.T.IOCGWINSZ))), &ws) != 0)
            return error.IoctlFailed;
    } else {
        if (!ok(posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws))))
            return error.IoctlFailed;
    }
    return ws;
}

fn openTty() !Fd {
    return posix.openatZ(posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0);
}

var wake_fd: Fd = -1;
var winch_count: u32 = 0;

fn onWinch(_: posix.SIG) callconv(.c) void {
    if (wake_fd < 0) return;
    const byte = [_]u8{0};
    if (via_libc) {
        const saved = std.c._errno().*;
        _ = posix.system.write(wake_fd, &byte, 1);
        std.c._errno().* = saved;
    } else {
        _ = posix.system.write(wake_fd, &byte, 1);
    }
}

// --- reporting --------------------------------------------------------------

var passed: u32 = 0;
var failed: u32 = 0;
var skipped: u32 = 0;

/// Buffered so a failure mid-suite still gets flushed. Written with \r\n
/// because part of the suite runs with OPOST off.
var obuf: [16 * 1024]u8 = undefined;
var olen: usize = 0;

fn emit(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(obuf[olen..], fmt, args) catch return;
    olen += s.len;
}

fn flush() void {
    if (olen == 0) return;
    sysWriteAll(1, obuf[0..olen]) catch {};
    olen = 0;
}

fn pass(name: []const u8, comptime fmt: []const u8, args: anytype) void {
    passed += 1;
    emit("  PASS  {s: <34}", .{name});
    emit(fmt, args);
    emit("\r\n", .{});
}

fn fail(name: []const u8, comptime fmt: []const u8, args: anytype) void {
    failed += 1;
    emit("  FAIL  {s: <34}", .{name});
    emit(fmt, args);
    emit("\r\n", .{});
}

fn skip(name: []const u8, comptime fmt: []const u8, args: anytype) void {
    skipped += 1;
    emit("  SKIP  {s: <34}", .{name});
    emit(fmt, args);
    emit("\r\n", .{});
}

fn expect(name: []const u8, cond: bool, comptime fmt: []const u8, args: anytype) void {
    if (cond) pass(name, fmt, args) else fail(name, fmt, args);
}

// --- helpers ----------------------------------------------------------------

fn readSmallFile(path: [*:0]const u8, buf: []u8) ?usize {
    const fd = posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer sysClose(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch return null;
        if (n == 0) break;
        total += n;
    }
    return total;
}

// --- checks -----------------------------------------------------------------

fn checkBuildConfig() void {
    emit("\r\nBuild configuration\r\n", .{});
    emit("  os={s} arch={s} abi={s}\r\n", .{
        @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), @tagName(builtin.abi),
    });
    emit("  link_libc={} posix.system={s}\r\n", .{
        builtin.link_libc,
        if (via_libc) "std.c" else "std.os.linux (raw syscalls)",
    });

    if (builtin.os.tag == .linux) {
        expect(
            "built without libc",
            !builtin.link_libc,
            "link_libc={}",
            .{builtin.link_libc},
        );
    } else {
        skip("built without libc", "macOS always links libSystem", .{});
    }
}

/// The strongest runtime proof available: ask the kernel what this process
/// actually mapped. A libc-free binary has no libc.so in its address space.
fn checkNoLibcMapped() void {
    if (builtin.os.tag != .linux) {
        skip("no libc in /proc/self/maps", "linux only", .{});
        return;
    }
    var buf: [64 * 1024]u8 = undefined;
    const n = readSmallFile("/proc/self/maps", &buf) orelse {
        skip("no libc in /proc/self/maps", "could not read /proc", .{});
        return;
    };
    const maps = buf[0..n];
    const has_libc = std.mem.indexOf(u8, maps, "libc.so") != null or
        std.mem.indexOf(u8, maps, "ld-linux") != null or
        std.mem.indexOf(u8, maps, "ld-musl") != null;
    expect(
        "no libc in /proc/self/maps",
        !has_libc,
        "{d} bytes of maps scanned",
        .{n},
    );
}

fn checkPipe() void {
    const p = selfPipe() catch {
        fail("pipe2 O_NONBLOCK|O_CLOEXEC", "syscall failed", .{});
        return;
    };
    defer {
        sysClose(p[0]);
        sysClose(p[1]);
    }
    pass("pipe2 O_NONBLOCK|O_CLOEXEC", "read={d} write={d}", .{ p[0], p[1] });

    sysWriteAll(p[1], "x") catch {
        fail("write/read round trip", "write failed", .{});
        return;
    };
    var b: [1]u8 = undefined;
    const n = posix.read(p[0], &b) catch {
        fail("write/read round trip", "read failed", .{});
        return;
    };
    expect("write/read round trip", n == 1 and b[0] == 'x', "got {d} byte(s)", .{n});

    // A blocking read end would hang the event loop on a spurious wakeup.
    const again = posix.read(p[0], &b);
    expect(
        "pipe read end is non-blocking",
        again == error.WouldBlock,
        "empty read -> {any}",
        .{again},
    );

    // CLOEXEC, checked directly rather than by spawning. fcntl's signature
    // differs between the two backends: variadic and signed under libc, a
    // usize-arg syscall without it.
    const fd_flags: i64 = if (via_libc)
        @intCast(std.c.fcntl(p[0], posix.F.GETFD, @as(c_int, 0)))
    else
        @bitCast(@as(u64, posix.system.fcntl(p[0], posix.F.GETFD, @as(usize, 0))));
    expect(
        "pipe is close-on-exec",
        fd_flags >= 0 and (fd_flags & 1) == 1,
        "FD_CLOEXEC bit={d}",
        .{fd_flags & 1},
    );
}

/// The check most likely to fail on a libc-free build: rt_sigaction needs a
/// restorer trampoline that libc normally supplies.
fn checkSignals() void {
    const p = selfPipe() catch {
        fail("sigaction installs handler", "pipe failed", .{});
        return;
    };
    defer {
        sysClose(p[0]);
        sysClose(p[1]);
    }
    wake_fd = p[1];
    defer wake_fd = -1;

    var act: posix.Sigaction = .{
        .handler = .{ .handler = onWinch },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &act, null);
    pass("sigaction installs handler", "SIGWINCH", .{});

    // Delivery: the handler must run and reach the pipe.
    posix.raise(posix.SIG.WINCH) catch {
        fail("SIGWINCH handler runs", "raise failed", .{});
        return;
    };

    var fds = [_]posix.pollfd{.{ .fd = p[0], .events = posix.POLL.IN, .revents = 0 }};
    const nready = posix.poll(&fds, 500) catch {
        fail("SIGWINCH wakes poll", "poll failed", .{});
        return;
    };
    expect(
        "SIGWINCH wakes poll",
        nready == 1 and (fds[0].revents & posix.POLL.IN) != 0,
        "poll -> {d} ready",
        .{nready},
    );

    // Coalescing: several signals must drain to nothing, leaving the loop
    // ready to block again rather than spinning once per notification.
    var i: u32 = 0;
    while (i < 8) : (i += 1) posix.raise(posix.SIG.WINCH) catch {};

    var drained: usize = 0;
    var db: [64]u8 = undefined;
    while (true) {
        const n = posix.read(p[0], &db) catch break;
        if (n == 0) break;
        drained += n;
    }
    const empty = posix.read(p[0], &db);
    expect(
        "self-pipe drains fully",
        empty == error.WouldBlock,
        "{d} byte(s) drained, then WouldBlock",
        .{drained},
    );

    posix.sigaction(posix.SIG.WINCH, &.{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);
}

fn checkPollTimeout() void {
    const p = selfPipe() catch {
        fail("poll honours finite timeout", "pipe failed", .{});
        return;
    };
    defer {
        sysClose(p[0]);
        sysClose(p[1]);
    }
    // This is the escape-disambiguation path: a finite timeout with no input.
    var fds = [_]posix.pollfd{.{ .fd = p[0], .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, 25) catch {
        fail("poll honours finite timeout", "poll failed", .{});
        return;
    };
    expect("poll honours finite timeout", n == 0, "25ms timeout -> {d} ready", .{n});
}

fn checkUtf8() void {
    const cases = [_]struct { s: []const u8, cp: u21 }{
        .{ .s = "e", .cp = 'e' },
        .{ .s = "é", .cp = 0xE9 },
        .{ .s = "世", .cp = 0x4E16 },
        .{ .s = "🙂", .cp = 0x1F642 },
    };
    var all = true;
    for (cases) |c| {
        const len = std.unicode.utf8ByteSequenceLength(c.s[0]) catch {
            all = false;
            continue;
        };
        const cp = std.unicode.utf8Decode(c.s[0..len]) catch {
            all = false;
            continue;
        };
        if (cp != c.cp or len != c.s.len) all = false;
    }
    expect("incremental UTF-8 decode", all, "1/2/3/4-byte sequences", .{});
}

fn checkTerminal() void {
    const fd = openTty() catch {
        skip("open /dev/tty", "no controlling terminal", .{});
        skip("TIOCGWINSZ", "no terminal", .{});
        skip("tcgetattr", "no terminal", .{});
        skip("raw mode applies", "no terminal", .{});
        skip("termios restored", "no terminal", .{});
        skip("ANSI write to terminal", "no terminal", .{});
        return;
    };
    defer sysClose(fd);
    pass("open /dev/tty", "fd={d}", .{fd});

    if (winsize(fd)) |ws| {
        // 0x0 is legal (a pty with no dimensions set) and must not be an error.
        pass("TIOCGWINSZ", "{d} rows x {d} cols", .{ ws.row, ws.col });
    } else |_| {
        fail("TIOCGWINSZ", "ioctl failed", .{});
    }

    // tcgetattr/tcsetattr are libc wrappers over TCGETS/TCSETS ioctls; without
    // libc, std.posix must issue those ioctls itself.
    const saved = posix.tcgetattr(fd) catch {
        fail("tcgetattr", "failed", .{});
        skip("raw mode applies", "no saved termios", .{});
        skip("termios restored", "no saved termios", .{});
        return;
    };
    pass("tcgetattr", "saved original attributes", .{});

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
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.PARENB = false;
    raw.cflag.CSIZE = .CS8;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    posix.tcsetattr(fd, .NOW, raw) catch {
        fail("raw mode applies", "tcsetattr failed", .{});
        return;
    };

    // Read back rather than trusting the write: this is the check that proves
    // the ioctl actually reached the driver.
    if (posix.tcgetattr(fd)) |now| {
        const is_raw = !now.lflag.ECHO and !now.lflag.ICANON and
            !now.lflag.ISIG and !now.oflag.OPOST;
        expect("raw mode applies", is_raw, "ECHO/ICANON/ISIG/OPOST all off", .{});
    } else |_| {
        fail("raw mode applies", "tcgetattr after set failed", .{});
    }

    // A frame's worth of ANSI, written the way Screen.present will.
    const frame = "\x1b[s\x1b[1;1H\x1b[7m zooi \x1b[0m\x1b[u";
    if (sysWriteAll(fd, frame)) {
        pass("ANSI write to terminal", "{d} bytes in one write", .{frame.len});
    } else |_| {
        fail("ANSI write to terminal", "write failed", .{});
    }

    posix.tcsetattr(fd, .DRAIN, saved) catch {
        fail("termios restored", "tcsetattr failed", .{});
        return;
    };
    if (posix.tcgetattr(fd)) |back| {
        const restored = back.lflag.ECHO == saved.lflag.ECHO and
            back.lflag.ICANON == saved.lflag.ICANON and
            back.oflag.OPOST == saved.oflag.OPOST;
        expect("termios restored", restored, "matches the saved attributes", .{});
    } else |_| {
        fail("termios restored", "tcgetattr after restore failed", .{});
    }
}

/// Optional: decodes one real keypress. Skipped unless stdin is a terminal.
fn checkInteractiveKey() void {
    const fd = openTty() catch {
        skip("decode a real keypress", "no terminal", .{});
        return;
    };
    defer sysClose(fd);

    const saved = posix.tcgetattr(fd) catch {
        skip("decode a real keypress", "no termios", .{});
        return;
    };
    var raw = saved;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(fd, .NOW, raw) catch {
        skip("decode a real keypress", "cannot enter raw mode", .{});
        return;
    };
    defer posix.tcsetattr(fd, .DRAIN, saved) catch {};

    emit("\r\n  Press the UP ARROW key (or wait 8s to skip)... ", .{});
    flush();

    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, 8000) catch 0;
    if (n == 0) {
        emit("\r\n", .{});
        skip("decode a real keypress", "no key pressed", .{});
        return;
    }
    var b: [32]u8 = undefined;
    const got = posix.read(fd, &b) catch 0;
    emit("\r\n", .{});
    if (got == 0) {
        skip("decode a real keypress", "empty read", .{});
        return;
    }
    const seq = b[0..got];
    const is_up = std.mem.eql(u8, seq, "\x1b[A") or std.mem.eql(u8, seq, "\x1bOA");
    if (is_up) {
        pass("decode a real keypress", "{d} bytes -> Up", .{got});
    } else {
        // Not a failure: any key proves the read path works.
        pass("decode a real keypress", "{d} bytes read (not Up, but input works)", .{got});
    }
}

// --- main -------------------------------------------------------------------

pub fn main() !u8 {
    emit("zooi-verify - runtime check of zooi's terminal primitives\r\n", .{});

    checkBuildConfig();

    emit("\r\nSyscalls used by src/sys.zig\r\n", .{});
    checkNoLibcMapped();
    checkPipe();
    checkPollTimeout();

    emit("\r\nSignal handling (spec 11.2)\r\n", .{});
    checkSignals();

    emit("\r\nInput decoding (spec 12.2)\r\n", .{});
    checkUtf8();

    emit("\r\nTerminal lifecycle (spec 13)\r\n", .{});
    checkTerminal();
    flush();

    checkInteractiveKey();

    emit("\r\n{d} passed, {d} failed, {d} skipped\r\n", .{ passed, failed, skipped });
    if (failed == 0) {
        emit("RESULT: OK - zooi's primitives work on this system.\r\n", .{});
    } else {
        emit("RESULT: FAILURES - paste this output back.\r\n", .{});
    }
    flush();
    return if (failed == 0) 0 else 1;
}
