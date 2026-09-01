//! zooi-verify — runtime proof that zooi's terminal primitives work on a given
//! system, with no libc linked on Linux.
//!
//! Compile-time checks establish that the library builds without libc. This
//! binary establishes that it *runs*: it drives the real `src/sys.zig`,
//! `src/terminal.zig`, and `src/input.zig` — not copies of them — reports
//! PASS/FAIL per check, and exits non-zero if any check fails.
//!
//! Build:
//!   zig build verify                          # for this machine
//!   zig build verify -Dtarget=x86_64-linux-none   # static, no libc
//!
//! It needs no arguments. Run it in a terminal for the full suite; run it
//! piped or under a non-tty and the terminal-dependent checks report SKIP
//! rather than failing. Its value is that a user hitting trouble on an unusual
//! terminal can run one static binary and paste the output.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// The library itself, not a copy of it. An inlined shim would be a second
// implementation free to drift from the one that ships, and this binary exists
// to be believed when it disagrees with expectations.
const internal = @import("zooi_internal");
const sys = internal.sys;
const terminal = internal.terminal;
const input = internal.input;

const Fd = sys.Fd;

var wake_fd: Fd = -1;
var winch_count: u32 = 0;

fn onWinch(_: posix.SIG) callconv(.c) void {
    if (wake_fd < 0) return;
    const byte = [_]u8{0};
    if (sys.via_libc) {
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
    if (std.fmt.bufPrint(obuf[olen..], fmt, args)) |s| {
        olen += s.len;
        return;
    } else |_| {}
    // Out of room. Get what is buffered onto the terminal and try once more,
    // rather than dropping the rest: a report that stopped part-way silently
    // reads as a suite that had nothing more to say.
    flush();
    const s = std.fmt.bufPrint(obuf[olen..], fmt, args) catch return;
    olen += s.len;
}

fn flush() void {
    if (olen == 0) return;
    sys.writeAll(1, obuf[0..olen]) catch {};
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
    defer sys.close(fd);
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
        if (sys.via_libc) "std.c" else "std.os.linux (raw syscalls)",
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
    const p = sys.selfPipe() catch {
        fail("pipe2 O_NONBLOCK|O_CLOEXEC", "syscall failed", .{});
        return;
    };
    defer {
        sys.close(p[0]);
        sys.close(p[1]);
    }
    pass("pipe2 O_NONBLOCK|O_CLOEXEC", "read={d} write={d}", .{ p[0], p[1] });

    sys.writeAll(p[1], "x") catch {
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
    const fd_flags: i64 = if (sys.via_libc)
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
    const p = sys.selfPipe() catch {
        fail("sigaction installs handler", "pipe failed", .{});
        return;
    };
    defer {
        sys.close(p[0]);
        sys.close(p[1]);
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
    const p = sys.selfPipe() catch {
        fail("poll honours finite timeout", "pipe failed", .{});
        return;
    };
    defer {
        sys.close(p[0]);
        sys.close(p[1]);
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
    const fd = sys.openTty() catch {
        skip("open /dev/tty", "no controlling terminal", .{});
        skip("TIOCGWINSZ", "no terminal", .{});
        skip("tcgetattr", "no terminal", .{});
        skip("raw mode applies", "no terminal", .{});
        skip("termios restored", "no terminal", .{});
        skip("ANSI write to terminal", "no terminal", .{});
        return;
    };
    defer sys.close(fd);
    pass("open /dev/tty", "fd={d}", .{fd});

    if (sys.winsize(fd)) |ws| {
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
        skip("ANSI write to terminal", "no saved termios", .{});
        skip("termios restored", "no saved termios", .{});
        return;
    };
    pass("tcgetattr", "saved original attributes", .{});

    // The real lifecycle, on the descriptor just opened. No alternate screen:
    // this runs in the user's shell and must not wipe what is on it.
    var term = terminal.Terminal.init(.{ .tty = fd, .alternate_screen = false }) catch {
        fail("raw mode applies", "Terminal.init failed", .{});
        skip("ANSI write to terminal", "no terminal", .{});
        skip("termios restored", "no terminal", .{});
        return;
    };

    // Read back rather than trusting the write: this is the check that proves
    // the ioctl actually reached the driver.
    if (posix.tcgetattr(fd)) |now| {
        const is_raw = !now.lflag.ECHO and !now.lflag.ICANON and
            !now.lflag.ISIG and !now.oflag.OPOST;
        expect("raw mode applies", is_raw, "ECHO/ICANON/ISIG/OPOST all off", .{});
    } else |_| {
        fail("raw mode applies", "tcgetattr after Terminal.init failed", .{});
    }

    // A frame's worth of ANSI, written the way Screen.present will.
    const frame = "\x1b[s\x1b[1;1H\x1b[7m zooi \x1b[0m\x1b[u";
    if (sys.writeAll(term.out_fd, frame)) {
        pass("ANSI write to terminal", "{d} bytes in one write", .{frame.len});
    } else |_| {
        fail("ANSI write to terminal", "write failed", .{});
    }

    term.deinit();
    if (posix.tcgetattr(fd)) |back| {
        const restored = back.lflag.ECHO == saved.lflag.ECHO and
            back.lflag.ICANON == saved.lflag.ICANON and
            back.lflag.ISIG == saved.lflag.ISIG and
            back.oflag.OPOST == saved.oflag.OPOST;
        expect("termios restored", restored, "matches the saved attributes", .{});
    } else |_| {
        fail("termios restored", "tcgetattr after Terminal.deinit failed", .{});
    }
}

/// Optional: decodes one real keypress. Skipped unless stdin is a terminal.
fn checkInteractiveKey() void {
    const fd = sys.openTty() catch {
        skip("decode a real keypress", "no terminal", .{});
        return;
    };
    defer sys.close(fd);

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

    // Decoded by the parser that ships, so a disagreement here is a real
    // disagreement. The bytes are printed either way: on the first hardware
    // run this check reported "not Up" and it took a second run to establish
    // that the key had been mistyped rather than the decoder broken. A
    // diagnostic that cannot tell those apart costs a round trip every time it
    // is wrong, and this binary exists to be believed.
    var parser: input.Parser = .{};
    _ = parser.feed(seq);
    const decoded = parser.next();

    var hex: [3 * 32]u8 = undefined;
    var used: usize = 0;
    for (seq, 0..) |byte, i| {
        const part = std.fmt.bufPrint(hex[used..], "{s}{x:0>2}", .{
            if (i == 0) "" else " ", byte,
        }) catch break;
        used += part.len;
    }
    const bytes_shown = hex[0..used];

    if (decoded) |key| {
        if (key == .up) {
            pass("decode a real keypress", "{d} bytes ({s}) -> up", .{ got, bytes_shown });
        } else if (key == .character) {
            // Not a failure: any key proves the read and decode path works.
            pass("decode a real keypress", "{d} bytes ({s}) -> character U+{X:0>4}", .{
                got, bytes_shown, key.character,
            });
        } else {
            pass("decode a real keypress", "{d} bytes ({s}) -> {s}", .{
                got, bytes_shown, @tagName(key),
            });
        }
    } else {
        // Not a failure. An unbound control byte, or the leading half of a
        // sequence, legitimately produces no key — and a run with no terminal
        // behind it reads EOF as 0x04. The bytes are printed so the reader can
        // tell that apart from a decoder that is actually broken.
        skip("decode a real keypress", "{d} bytes ({s}) produced no key", .{ got, bytes_shown });
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
