//! The frame buffer.
//!
//! Rendering is a full redraw every frame: `begin()`, a sequence of writes,
//! `present()`. There is no cell grid and no diff — the screen appends ANSI
//! bytes to one reusable buffer and flushes it in a single write. A terminal
//! holds little enough data that this is fast, and it removes an entire class
//! of stale-cell bugs.
//!
//! ## Why the screen is not cleared
//!
//! "Full redraw" describes what the application writes, not what the terminal
//! is told to do. Emitting `ESC [ 2 J` each frame blanks every cell and then
//! repaints it, which the eye reads as flicker and therefore as lag, even
//! though building the frame takes tens of microseconds.
//!
//! Instead a row is erased in full the first time the frame positions onto it,
//! and rows the frame never visited are blanked at `present()`. The visible
//! result is identical to clearing — no stale cell survives a frame, including
//! in the gaps of a row drawn at scattered columns — but the terminal repaints
//! a row at a time rather than blanking everything first.
//!
//! ## Rows and columns are 0-based
//!
//! Every index in zooi is 0-based; the conversion to the terminal's 1-based
//! coordinates happens inside `move`. One 1-based coordinate system in the
//! middle of a 0-based library is a reliable source of off-by-one bugs.
//!
//! ## Writes cannot fail
//!
//! The mutating calls return `void`. If the buffer cannot grow, the first
//! failure is latched and returned by `present()`, and every later call in
//! that frame is a no-op. An application's render is a long sequence of small
//! writes; making each one fallible would force `try` onto every line of a
//! layout routine and infect every helper's signature. Latching keeps
//! `fn render(model, screen) void` — callable from a test with no terminal and
//! no error handling — while still reporting failure at exactly one place.

const std = @import("std");
const Allocator = std.mem.Allocator;

const sys = @import("sys.zig");
const width = @import("width.zig");
const Size = @import("event.zig").Size;

pub const Color = union(enum) {
    /// The terminal's own 16 colors. Prefer this: it respects the palette the
    /// user chose.
    ansi: u4,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Style = struct {
    /// Null means the terminal's default, which is not the same as any
    /// particular color and is emitted as SGR 39 / 49.
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,

    pub const default: Style = .{};
};

pub const Error = error{ OutOfMemory, WriteFailed };

/// Rows the visited-set can track. A terminal taller than this falls back to
/// clearing the screen, which is correct and merely flickers.
const max_tracked_rows = 1024;

pub const Screen = struct {
    /// Terminal dimensions as of the last resize. Read this in `render` to lay
    /// out; it is never stale within a frame.
    size: Size,

    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    fd: sys.Fd,

    /// Logical cursor, tracked so writes can be clipped.
    row: u16 = 0,
    col: u16 = 0,
    /// Style last emitted, so redundant SGR sequences are skipped.
    emitted: Style = .{},
    /// Where to leave the terminal cursor, if the frame asked for one.
    cursor: ?struct { row: u16, col: u16 } = null,
    /// First failure of the frame, returned by `present`.
    err: ?Error = null,

    /// Rows this frame has positioned onto. Each is erased on first visit;
    /// whatever is left over is blanked at present() so no stale content
    /// survives.
    visited: [max_tracked_rows / 8]u8 = @splat(0),

    pub fn init(gpa: Allocator, fd: sys.Fd, size: Size) Screen {
        return .{ .size = size, .gpa = gpa, .fd = fd };
    }

    pub fn deinit(self: *Screen) void {
        self.buf.deinit(self.gpa);
    }

    /// Start a frame: reset style, clear, home the cursor, hide it.
    ///
    /// Retains the buffer's capacity, so steady-state rendering does not
    /// allocate after the first few frames.
    pub fn begin(self: *Screen) void {
        self.buf.clearRetainingCapacity();
        self.row = 0;
        self.col = 0;
        self.emitted = .{};
        self.cursor = null;
        self.err = null;
        self.visited = @splat(0);
        self.raw("\x1b[0m\x1b[H\x1b[?25l");
        // A terminal too tall to track is cleared outright rather than left
        // with stale rows.
        if (self.size.rows > max_tracked_rows) self.raw("\x1b[2J");
    }

    /// Move the logical cursor. 0-based; converted to the terminal's 1-based
    /// coordinates here.
    pub fn move(self: *Screen, row: u16, col: u16) void {
        self.row = row;
        self.col = col;
        if (self.offScreen()) return;

        // The first visit to a row erases the whole row, so a frame that
        // draws at scattered columns has blank gaps rather than last frame's
        // content. Later moves within the same row must not erase again.
        if (!self.wasVisited(row)) {
            self.markVisited(row);
            self.print("\x1b[{d};1H\x1b[K", .{row + 1});
            if (col == 0) return;
        }
        self.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    pub fn write(self: *Screen, text: []const u8) void {
        self.writeStyled(text, self.emitted);
    }

    pub fn writeStyled(self: *Screen, text: []const u8, style: Style) void {
        if (self.err != null or self.offScreen()) return;
        self.applyStyle(style);
        self.writeClipped(text);
    }

    pub fn clearToEndOfLine(self: *Screen) void {
        if (self.err != null or self.offScreen()) return;
        self.raw("\x1b[K");
    }

    /// Leave the terminal cursor here when the frame is presented, and make it
    /// visible. Text prompts need this; a frame that never calls it presents
    /// with the cursor hidden.
    pub fn showCursor(self: *Screen, row: u16, col: u16) void {
        self.cursor = .{ .row = row, .col = col };
    }

    /// Flush the frame in a single write.
    pub fn present(self: *Screen) Error!void {
        self.blankUnvisited();
        if (self.cursor) |c| {
            if (c.row < self.size.rows and c.col < self.size.cols)
                self.print("\x1b[{d};{d}H\x1b[?25h", .{ c.row + 1, c.col + 1 });
        }
        if (self.err) |e| return e;
        sys.writeAll(self.fd, self.buf.items) catch return error.WriteFailed;
    }

    /// The frame's bytes. For tests; consumers have no reason to read this.
    pub fn frame(self: *const Screen) []const u8 {
        return self.buf.items;
    }

    // --- internals ---------------------------------------------------------

    fn markVisited(self: *Screen, row: u16) void {
        if (row >= max_tracked_rows) return;
        self.visited[row / 8] |= @as(u8, 1) << @intCast(row % 8);
    }

    fn wasVisited(self: *const Screen, row: u16) bool {
        if (row >= max_tracked_rows) return true;
        return self.visited[row / 8] & (@as(u8, 1) << @intCast(row % 8)) != 0;
    }

    /// Blank every row the frame never positioned onto. This is what replaces
    /// the screen-wide clear, and it costs nothing for a frame that draws
    /// every row.
    fn blankUnvisited(self: *Screen) void {
        if (self.size.rows > max_tracked_rows) return;
        var row: u16 = 0;
        while (row < self.size.rows) : (row += 1) {
            if (self.wasVisited(row)) continue;
            self.print("\x1b[{d};1H\x1b[K", .{row + 1});
        }
    }

    fn offScreen(self: *const Screen) bool {
        return self.row >= self.size.rows or self.col >= self.size.cols;
    }

    fn raw(self: *Screen, bytes: []const u8) void {
        if (self.err != null) return;
        self.buf.appendSlice(self.gpa, bytes) catch {
            self.err = error.OutOfMemory;
        };
    }

    fn print(self: *Screen, comptime fmt: []const u8, args: anytype) void {
        if (self.err != null) return;
        self.buf.print(self.gpa, fmt, args) catch {
            self.err = error.OutOfMemory;
        };
    }

    /// Append text, dropping anything unprintable and stopping at the right
    /// edge. Sanitising and measuring happen in one pass because they have to:
    /// a dropped control byte must not consume a column.
    fn writeClipped(self: *Screen, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            const s = width.step(text[i..]);
            i += s.len;

            // Control bytes never reach the terminal. A recorded command can
            // contain a stray CR; if it got through, the row would be
            // overwritten from column zero and the whole frame would be wrong.
            if (s.cp) |cp| {
                if (cp < 0x20 or cp == 0x7f) continue;
            } else {
                continue; // malformed bytes are dropped too
            }

            const remaining = self.size.cols - self.col;
            if (s.width > remaining) {
                // A wide character straddling the edge is replaced by a space
                // rather than half-drawn: half a wide character corrupts the
                // terminal's own column tracking for the rest of the line.
                if (remaining > 0) {
                    self.raw(" ");
                    self.col += 1;
                }
                return;
            }

            self.raw(text[i - s.len ..][0..s.len]);
            self.col += s.width;
            if (self.col >= self.size.cols) return;
        }
    }

    fn applyStyle(self: *Screen, style: Style) void {
        if (std.meta.eql(style, self.emitted)) return;
        self.emitted = style;

        self.raw("\x1b[0m");
        if (style.bold) self.raw("\x1b[1m");
        if (style.dim) self.raw("\x1b[2m");
        if (style.italic) self.raw("\x1b[3m");
        if (style.underline) self.raw("\x1b[4m");
        if (style.reverse) self.raw("\x1b[7m");
        self.color(style.fg, true);
        self.color(style.bg, false);
    }

    fn color(self: *Screen, c: ?Color, fg: bool) void {
        const base: u8 = if (fg) 30 else 40;
        const ext: u8 = if (fg) 38 else 48;
        const reset: u8 = if (fg) 39 else 49;

        const value = c orelse {
            self.print("\x1b[{d}m", .{reset});
            return;
        };
        switch (value) {
            // 0-7 are the normal colors, 8-15 the bright ones at +60.
            .ansi => |n| self.print("\x1b[{d}m", .{
                if (n < 8) base + @as(u8, n) else base + 60 + (@as(u8, n) - 8),
            }),
            .indexed => |n| self.print("\x1b[{d};5;{d}m", .{ ext, n }),
            .rgb => |v| self.print("\x1b[{d};2;{d};{d};{d}m", .{ ext, v.r, v.g, v.b }),
        }
    }
};
