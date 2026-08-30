//! The event source: one blocking wait over the terminal and a self-pipe.
//!
//! Spec properties this loop has to preserve, all of them falsifiable: one
//! thread, blocking while idle, no periodic polling, no async runtime, no
//! worker pool, and all rendering and state changes on the loop. That list is
//! the whole of the concurrency design — a timer thread added to handle the
//! escape timeout would break every line of it.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const sys = @import("sys.zig");
const terminal = @import("terminal.zig");
const input = @import("input.zig");
const screen_mod = @import("screen.zig");

const Screen = screen_mod.Screen;
const Key = input.Key;

/// Terminal dimensions.
///
/// Either field may legitimately be `0`: a pty with no size set reports
/// `0 x 0`, which was observed on real hardware and is not an error. Callers
/// clip rather than assume a minimum.
pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const Event = union(enum) {
    key: Key,
    resize: Size,
};

pub const Error = terminal.Error || error{ OutOfMemory, ReadFailed, PollFailed };

pub const Ui = struct {
    pub const Options = struct {
        /// Override the terminal descriptor. Null opens /dev/tty.
        tty: ?sys.Fd = null,
        alternate_screen: bool = true,
        /// Present complete frames atomically on terminals that implement DEC
        /// mode 2026. Unsupported terminals normally ignore the mode.
        synchronized_output: bool = true,
        /// Compress long runs of styled spaces with REP. Off by default: a
        /// terminal that does not implement REP drops it silently and paints
        /// styled backgrounds short, and the saving is under 100 bytes a frame.
        repeat_sequences: bool = false,
        /// How long a lone ESC waits for the rest of a sequence before being
        /// taken as the Escape key. 25ms is long enough that a local
        /// terminal's arrow-key bytes always arrive together and short enough
        /// that Escape feels immediate; a slow link may want more.
        escape_timeout_ms: u16 = 25,
    };

    term: terminal.Terminal,
    scr: Screen,
    parser: input.Parser = .{},
    escape_timeout_ms: u16,
    last_size: Size,

    pub fn init(gpa: Allocator, options: Options) Error!Ui {
        var term = try terminal.Terminal.init(.{
            .tty = options.tty,
            .alternate_screen = options.alternate_screen,
            .synchronized_output = options.synchronized_output,
        });
        errdefer term.deinit();

        const dims = term.size();
        var scr = Screen.init(gpa, term.out_fd, dims);
        scr.setSynchronizedOutput(options.synchronized_output);
        scr.setRepeatSequences(options.repeat_sequences);
        return .{
            .term = term,
            .scr = scr,
            .escape_timeout_ms = options.escape_timeout_ms,
            .last_size = dims,
        };
    }

    pub fn deinit(self: *Ui) void {
        self.scr.deinit();
        self.term.deinit();
    }

    /// The frame buffer. Render into it, then call `present()` on it.
    pub fn screen(self: *Ui) *Screen {
        return &self.scr;
    }

    pub fn size(self: *const Ui) Size {
        return self.last_size;
    }

    /// Block until a key is pressed or the terminal is resized.
    ///
    /// Returns null when the input stream ends, which for a terminal means the
    /// session is over.
    pub fn nextEvent(self: *Ui) Error!?Event {
        return self.readEvent(true);
    }

    /// Return the next event that is already queued, without blocking.
    ///
    /// Applications can call this after `nextEvent()` to apply a burst of
    /// input before rendering once. Null means no complete event is available
    /// now, or that the input stream ended.
    pub fn pollEvent(self: *Ui) Error!?Event {
        return self.readEvent(false);
    }

    fn readEvent(self: *Ui, block: bool) Error!?Event {
        while (true) {
            // Drain the parser before any syscall: one read can carry several
            // keys, and polling between them would be both wrong and slow.
            if (self.parser.next()) |key| return .{ .key = key };

            // nextEvent uses a finite timeout only while an escape sequence is
            // half-arrived and otherwise blocks indefinitely. pollEvent uses
            // zero so applications can drain a burst without waiting.
            const timeout: i32 = if (!block)
                0
            else if (self.parser.awaitingEscape())
                @intCast(self.escape_timeout_ms)
            else
                -1;

            var fds = [_]posix.pollfd{
                .{ .fd = self.term.in_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.term.wakeFd(), .events = posix.POLL.IN, .revents = 0 },
            };

            // std.posix.poll retries EINTR itself, so a signal arriving mid-wait
            // needs no handling here.
            const ready = posix.poll(&fds, timeout) catch return error.PollFailed;

            if (ready == 0) {
                if (!block) return null;
                // Nothing arrived in time: the pending ESC was the key.
                if (self.parser.timeout()) |key| return .{ .key = key };
                continue;
            }

            // Resize first when both are ready: pending keystrokes were typed
            // after the resize, so they should be interpreted against the new
            // size.
            if (fds[1].revents & posix.POLL.IN != 0) {
                if (self.handleResize()) |event| return event;
                continue;
            }

            if (fds[0].revents & posix.POLL.IN != 0) {
                var buf: [1024]u8 = undefined;
                // The kernel may have accumulated many complete keys while
                // the application rendered the previous event. Read only
                // what the parser can retain; reading the whole available
                // burst and passing it to a smaller parser would discard it.
                // A full parser contains one overlong, incomplete sequence;
                // reading one more byte deliberately takes feed's overflow
                // recovery path and lets the stream resynchronise.
                const room = self.parser.feedCapacity();
                const read_len = if (room == 0) 1 else @min(room, buf.len);
                const n = posix.read(self.term.in_fd, buf[0..read_len]) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => return error.ReadFailed,
                };
                if (n == 0) return null; // end of stream
                _ = self.parser.feed(buf[0..n]);
                continue;
            }

            // Hangup or error on either descriptor ends the session. Both are
            // checked: with `events` set to POLL.IN, the only revents a
            // descriptor can report are IN and these three, so covering them
            // here makes the loop total. Missing one would leave poll returning
            // the same unhandled condition forever at full CPU.
            const broken = posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;
            if ((fds[0].revents | fds[1].revents) & broken != 0) return null;
        }
    }

    /// Collapse every pending notification into at most one event.
    fn handleResize(self: *Ui) ?Event {
        self.term.drainWake();
        const now = self.term.size();
        // A burst during a window drag costs one redraw, not forty — and a
        // notification that did not actually change the size costs none.
        if (now.rows == self.last_size.rows and now.cols == self.last_size.cols)
            return null;
        self.last_size = now;
        // Update the screen before returning, or the application's next render
        // clips to the old width for exactly one visibly wrong frame.
        self.scr.size = now;
        return .{ .resize = now };
    }
};
