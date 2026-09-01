//! Test support: run a program under a pty we control, so zooi is exercised
//! the way a terminal emulator drives it.
//!
//! Only this artifact links libc. `posix_openpt`, `grantpt`, `unlockpt`, and
//! `ptsname` have no raw-syscall spelling worth maintaining for a test, and
//! the library itself stays libc-free — the `portability` CI job proves it.
//!
//! The child's stderr is a pipe rather than the pty. The example announces
//! every painted frame there, so a test waits for a marker instead of sleeping,
//! and the pty stream stays a clean record of the interface. Nothing in here
//! sleeps for a fixed duration and then asserts: that is how a terminal suite
//! becomes something everybody learns to ignore.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const Allocator = std.mem.Allocator;

pub const Fd = posix.fd_t;

extern "c" fn posix_openpt(oflag: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// `std.posix.T` carries only some of the terminal ioctl numbers on Darwin.
const Ioctl = switch (builtin.os.tag) {
    .linux => struct {
        const SWINSZ = posix.T.IOCSWINSZ;
        const SCTTY = posix.T.IOCSCTTY;
    },
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        const SWINSZ = 0x80087467;
        const SCTTY = 0x20007461;
    },
    else => @compileError("the PTY suite supports macOS and Linux"),
};

/// ioctl request numbers are unsigned constants that do not always fit the
/// signed c_int the variadic prototype takes.
fn request(comptime value: comptime_int) c_int {
    return @bitCast(@as(u32, value));
}

pub const Error = error{ PtyUnavailable, SpawnFailed } || Allocator.Error;

/// Which of the child's two streams a wait is watching.
pub const Stream = enum { output, marks };

pub const Options = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    /// Ask the example for per-frame markers on stderr.
    markers: bool = true,
};

pub const PtyChild = struct {
    gpa: Allocator,
    master: Fd,
    marks_fd: Fd,
    pid: c.pid_t,
    /// The pty's settings before the child touched them, so a test can assert
    /// restoration against what was actually there rather than against a
    /// guess at what a fresh pty looks like.
    initial: posix.termios,

    /// Everything the terminal received, and everything the child announced.
    output: std.ArrayList(u8) = .empty,
    marks: std.ArrayList(u8) = .empty,
    output_eof: bool = false,
    marks_eof: bool = false,
    reaped: ?u8 = null,

    pub fn deinit(self: *PtyChild) void {
        if (self.reaped == null) {
            _ = c.kill(self.pid, posix.SIG.KILL);
            _ = self.reap();
        }
        _ = c.close(self.master);
        _ = c.close(self.marks_fd);
        self.output.deinit(self.gpa);
        self.marks.deinit(self.gpa);
    }

    pub fn send(self: *PtyChild, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(self.master, bytes.ptr + off, bytes.len - off);
            if (n < 0) {
                // A signal landing mid-write is not a failed send. Treating it
                // as one would fail a test for a reason unrelated to zooi.
                if (posix.errno(n) == .INTR) continue;
                return error.SpawnFailed;
            }
            if (n == 0) return error.SpawnFailed;
            off += @intCast(n);
        }
    }

    /// Resize the terminal. The kernel raises SIGWINCH on the pty's foreground
    /// process group by itself; nothing here signals the child directly, or the
    /// test would pass even with the controlling terminal set up wrongly.
    pub fn resize(self: *PtyChild, rows: u16, cols: u16) !void {
        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (c.ioctl(self.master, request(Ioctl.SWINSZ), &ws) != 0) return error.SpawnFailed;
    }

    pub fn signal(self: *PtyChild, sig: posix.SIG) void {
        _ = c.kill(self.pid, sig);
    }

    /// The terminal settings the child is running under. A pty master and its
    /// slave share one line discipline, so this is what the child set.
    pub fn termios(self: *PtyChild) !posix.termios {
        return posix.tcgetattr(self.master) catch error.PtyUnavailable;
    }

    /// How many frames the child has announced so far.
    pub fn framesPainted(self: *const PtyChild) usize {
        return std.mem.count(u8, self.marks.items, "[zooi-frame ");
    }

    pub fn waitFrames(self: *PtyChild, n: usize, timeout_ms: i32) !bool {
        var needle: [32]u8 = undefined;
        const marker = std.fmt.bufPrint(&needle, "[zooi-frame {d}]", .{n}) catch unreachable;
        return self.waitFor(.marks, 0, marker, timeout_ms);
    }

    pub fn waitOutput(self: *PtyChild, needle: []const u8, timeout_ms: i32) !bool {
        return self.waitFor(.output, 0, needle, timeout_ms);
    }

    /// Like `waitOutput`, but only a match after `from` counts. Output already
    /// in the transcript must not be able to acknowledge input written later.
    pub fn waitOutputFrom(self: *PtyChild, from: usize, needle: []const u8, timeout_ms: i32) !bool {
        return self.waitFor(.output, from, needle, timeout_ms);
    }

    fn seen(self: *const PtyChild, stream: Stream, from: usize, needle: []const u8) bool {
        const items = switch (stream) {
            .output => self.output.items,
            .marks => self.marks.items,
        };
        const start = @min(from, items.len);
        return std.mem.indexOf(u8, items[start..], needle) != null;
    }

    /// Read both streams until the needle turns up or the budget runs out.
    /// Every wait is a poll that returns the instant bytes arrive.
    fn waitFor(self: *PtyChild, stream: Stream, from: usize, needle: []const u8, timeout_ms: i32) !bool {
        var remaining = timeout_ms;
        while (true) {
            if (self.seen(stream, from, needle)) return true;
            if (remaining <= 0) return false;
            if (!try self.step(&remaining)) return self.seen(stream, from, needle);
        }
    }

    /// Read whatever is available until both streams end or the budget runs
    /// out. Used before reaping, so the final bytes are not lost.
    pub fn drain(self: *PtyChild, timeout_ms: i32) !void {
        var remaining = timeout_ms;
        while (remaining > 0) {
            if (!try self.step(&remaining)) return;
        }
    }

    /// One poll-and-read across both live streams. False means nothing can
    /// arrive any more.
    fn step(self: *PtyChild, remaining: *i32) !bool {
        var fds: [2]posix.pollfd = undefined;
        var n: usize = 0;
        if (!self.output_eof) {
            fds[n] = .{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 };
            n += 1;
        }
        if (!self.marks_eof) {
            fds[n] = .{ .fd = self.marks_fd, .events = posix.POLL.IN, .revents = 0 };
            n += 1;
        }
        if (n == 0) return false;

        const slice: i32 = @min(remaining.*, 25);
        const ready = posix.poll(fds[0..n], slice) catch return false;
        if (ready == 0) {
            remaining.* -= slice;
            return true;
        }

        for (fds[0..n]) |p| {
            if (p.revents == 0) continue;
            const is_output = p.fd == self.master;
            var buf: [4096]u8 = undefined;
            // A pty master reports EIO rather than EOF once the child is gone,
            // so a read failure is the end of that stream — except EAGAIN,
            // which only means the bytes poll saw were taken already.
            const got = posix.read(p.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => 0,
            };
            if (got == 0) {
                if (is_output) self.output_eof = true else self.marks_eof = true;
                continue;
            }
            const list = if (is_output) &self.output else &self.marks;
            try list.appendSlice(self.gpa, buf[0..got]);
        }
        return true;
    }

    /// Drain, then reap. Kills the child if it outlives the budget, so a hung
    /// example fails one test instead of the whole run.
    pub fn wait(self: *PtyChild, timeout_ms: i32) !u8 {
        try self.drain(timeout_ms);
        if (!(self.output_eof and self.marks_eof)) _ = c.kill(self.pid, posix.SIG.KILL);
        return self.reap();
    }

    fn reap(self: *PtyChild) u8 {
        if (self.reaped) |code| return code;
        var status: c_int = 0;
        while (true) {
            const r = c.waitpid(self.pid, &status, 0);
            if (r >= 0) break;
            if (posix.errno(r) != .INTR) {
                self.reaped = 255;
                return 255;
            }
        }
        // WIFEXITED / WEXITSTATUS, spelled out: std does not expose them and
        // the encoding is the same on both platforms this suite supports.
        const code: u8 = if (status & 0x7f == 0)
            @intCast((status >> 8) & 0xff)
        else
            128 +| @as(u8, @intCast(status & 0x7f));
        self.reaped = code;
        return code;
    }

    /// The signal that killed the child, if one did.
    pub fn killedBy(self: *PtyChild) ?u8 {
        const code = self.reaped orelse return null;
        return if (code > 128) code - 128 else null;
    }
};

/// Fork a child onto a fresh pty. Returns `error.PtyUnavailable` when the
/// system has no pty to give, which is a skip rather than a failure.
pub fn spawn(gpa: Allocator, argv: []const []const u8, options: Options) Error!PtyChild {
    const pty = try openPty(options.rows, options.cols);
    errdefer {
        _ = c.close(pty.master);
        _ = c.close(pty.slave);
    }

    var marks: [2]c_int = undefined;
    if (c.pipe(&marks) != 0) return error.PtyUnavailable;
    errdefer {
        _ = c.close(marks[0]);
        _ = c.close(marks[1]);
    }

    // Keep the owning slices rather than recovering their lengths from the C
    // pointers later: an argument containing a NUL would be freed short.
    const owned = try gpa.alloc([:0]u8, argv.len);
    defer {
        for (owned) |word| gpa.free(word);
        gpa.free(owned);
    }
    const cargv = try gpa.allocSentinel(?[*:0]const u8, argv.len, null);
    defer gpa.free(cargv);
    for (argv, 0..) |word, i| {
        owned[i] = try gpa.dupeZ(u8, word);
        cargv[i] = owned[i].ptr;
    }

    const pid = c.fork();
    if (pid < 0) return error.SpawnFailed;
    if (pid == 0) {
        _ = c.close(pty.master);
        _ = c.close(marks[0]);
        _ = c.setsid();
        _ = c.ioctl(pty.slave, request(Ioctl.SCTTY), @as(c_int, 0));
        _ = c.dup2(pty.slave, 0);
        _ = c.dup2(pty.slave, 1);
        _ = c.dup2(marks[1], 2);
        if (pty.slave > 2) _ = c.close(pty.slave);
        if (marks[1] > 2) _ = c.close(marks[1]);
        if (options.markers) _ = setenv("ZOOI_EXAMPLE_MARKERS", "1", 1);
        _ = execv(cargv[0].?, cargv.ptr);
        c._exit(127);
    }

    _ = c.close(pty.slave);
    _ = c.close(marks[1]);
    return .{
        .gpa = gpa,
        .master = pty.master,
        .marks_fd = marks[0],
        .pid = pid,
        .initial = pty.initial,
    };
}

const Pty = struct { master: Fd, slave: Fd, initial: posix.termios };

fn openPty(rows: u16, cols: u16) Error!Pty {
    const flags: posix.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
    const master = posix_openpt(@bitCast(@as(u32, @bitCast(flags))));
    if (master < 0) return error.PtyUnavailable;
    errdefer _ = c.close(master);

    if (grantpt(master) != 0) return error.PtyUnavailable;
    if (unlockpt(master) != 0) return error.PtyUnavailable;
    const name = ptsname(master) orelse return error.PtyUnavailable;
    const slave = posix.openatZ(posix.AT.FDCWD, name, flags, 0) catch return error.PtyUnavailable;
    errdefer _ = c.close(slave);

    const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    if (c.ioctl(slave, request(Ioctl.SWINSZ), &ws) != 0) return error.PtyUnavailable;
    const initial = posix.tcgetattr(slave) catch return error.PtyUnavailable;
    return .{ .master = master, .slave = slave, .initial = initial };
}
