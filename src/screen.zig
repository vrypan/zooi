//! A retained terminal cell grid behind an immediate-mode drawing API.
//!
//! Applications still render a complete frame between `begin()` and
//! `present()`. Drawing populates a back grid instead of emitting ANSI
//! immediately; `present()` compares it with the last successfully presented
//! grid and writes only changed row spans. The application therefore keeps
//! the simple, stateless render function while cursor movement usually costs
//! two short row updates rather than a complete terminal repaint.
//!
//! Text for a cell lives in a per-frame byte arena. This matters for Unicode:
//! one grapheme cluster is retained per cell, up to the `max_cell_bytes`
//! ceiling that keeps unbounded combining input from growing one cell without
//! bound. Wide clusters occupy a head cell and a continuation cell, so
//! overwrites and diffs never leave half of one on screen.
//!
//! Every index exposed by this API is 0-based. ANSI coordinates are converted
//! to the terminal's 1-based convention only when a changed span is emitted.
//!
//! Drawing calls return `void`. Allocation failures are latched and returned
//! once by `present()`, keeping render functions free of error plumbing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const sys = @import("sys.zig");
const unicode = @import("zunic");
const Size = @import("event.zig").Size;

const begin_sync = "\x1b[?2026h";
const end_sync = "\x1b[?2026l";

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

const Cell = struct {
    /// Slice in the grid's matching text arena. len == 0 is an untouched,
    /// default-style blank cell.
    text_off: usize = 0,
    text_len: usize = 0,
    style: Style = .{},
    /// Display columns occupied by the head: 1 or 2. Continuations use 0.
    columns: u2 = 1,
    continuation: bool = false,

    const blank: Cell = .{};

    fn isBlank(self: Cell) bool {
        return self.text_len == 0 and !self.continuation;
    }
};

const Cursor = struct { row: u16, col: u16 };

/// Ceiling on the bytes one cell retains: a base codepoint plus the zero-width
/// marks that combine with it.
///
/// A cap is needed because zero-width marks do not advance the column, so
/// nothing else bounds them: a line of them lands in a single cell, and the
/// arena, the diff's comparison, and the bytes pushed at the terminal all grow
/// with the length of the input rather than with the size of the grid. A log
/// viewer showing another program's output is exactly where such a line comes
/// from. 32 bytes is well past any sequence a terminal will render — Unicode's
/// own stream-safe format stops at far fewer marks — and marks beyond it are
/// dropped, which is what the terminal would do with them anyway.
const max_cell_bytes = 32;

pub const Screen = struct {
    /// Terminal dimensions as of the last resize. Read this in `render` to lay
    /// out; it is never stale within a frame.
    size: Size,
    /// The geometry `begin()` allocated the back grid for.
    ///
    /// Every index, bound, and diff below is taken against this rather than
    /// `size`, because `size` can change part-way through a frame: `Ui`
    /// updates it from `handleResize`, and `pollEvent` is callable at any
    /// point. Re-reading `size` per cell would then index a grid allocated for
    /// the old dimensions — an out-of-bounds write, not a wrong pixel. A frame
    /// is drawn and presented with the geometry it began with; the next
    /// `begin()` picks up the new one and repaints from a clear screen.
    frame_size: Size = .{ .rows = 0, .cols = 0 },

    gpa: Allocator,
    /// Bytes emitted by the current `present()`. Exposed through `frame()` for
    /// tests and retained for allocation reuse.
    buf: std.ArrayList(u8) = .empty,
    fd: sys.Fd,

    front: std.ArrayList(Cell) = .empty,
    back: std.ArrayList(Cell) = .empty,
    front_text: std.ArrayList(u8) = .empty,
    back_text: std.ArrayList(u8) = .empty,
    front_size: Size = .{ .rows = 0, .cols = 0 },
    front_valid: bool = false,
    synchronized_output: bool = true,
    repeat_sequences: bool = false,

    /// Logical drawing cursor and style.
    row: u16 = 0,
    col: u16 = 0,
    draw_style: Style = .{},
    /// Style most recently emitted while constructing the ANSI diff.
    emitted: Style = .{},

    cursor: ?Cursor = null,
    err: ?Error = null,

    pub fn init(gpa: Allocator, fd: sys.Fd, size: Size) Screen {
        return .{ .size = size, .gpa = gpa, .fd = fd };
    }

    pub fn deinit(self: *Screen) void {
        self.buf.deinit(self.gpa);
        self.front.deinit(self.gpa);
        self.back.deinit(self.gpa);
        self.front_text.deinit(self.gpa);
        self.back_text.deinit(self.gpa);
    }

    /// Wrap each presented frame in DEC synchronized-output mode. Enabled by
    /// default; unsupported terminals normally ignore the private mode.
    pub fn setSynchronizedOutput(self: *Screen, enabled: bool) void {
        self.synchronized_output = enabled;
    }

    /// Compress long runs of styled spaces with REP. Disabled by default; see
    /// `emitSpaces` for why the saving is not worth the compatibility risk
    /// unless the terminal is known.
    pub fn setRepeatSequences(self: *Screen, enabled: bool) void {
        self.repeat_sequences = enabled;
    }

    /// Start a complete logical frame. The previous terminal image remains in
    /// `front`; only the reusable back grid is cleared.
    pub fn begin(self: *Screen) void {
        self.buf.clearRetainingCapacity();
        self.back_text.clearRetainingCapacity();
        self.row = 0;
        self.col = 0;
        self.draw_style = .{};
        self.emitted = .{};
        self.cursor = null;
        self.err = null;

        self.frame_size = self.size;
        const count = @as(usize, self.frame_size.rows) * @as(usize, self.frame_size.cols);
        self.back.resize(self.gpa, count) catch {
            self.err = error.OutOfMemory;
            return;
        };
        @memset(self.back.items, Cell.blank);

        // This small preamble is emitted even for an unchanged frame. It
        // gives every diff a known style and cursor state without retaining
        // terminal-global state that another writer could invalidate.
        if (self.synchronized_output) self.raw(begin_sync);
        self.raw("\x1b[0m\x1b[H\x1b[?25l");
    }

    /// Move the logical cursor. No terminal bytes are emitted until present.
    pub fn move(self: *Screen, row: u16, col: u16) void {
        self.row = row;
        self.col = col;
    }

    pub fn write(self: *Screen, text: []const u8) void {
        self.writeStyled(text, self.draw_style);
    }

    pub fn writeStyled(self: *Screen, text: []const u8, style: Style) void {
        // Recorded before the early return, so a following bare `write` uses
        // the style the application last asked for. Otherwise a call that
        // happened to land off-screen would silently leave the previous style
        // in place for the next one.
        self.draw_style = style;
        if (self.err != null or self.offScreen()) return;
        self.writeClipped(text, style);
    }

    pub fn clearToEndOfLine(self: *Screen) void {
        if (self.err != null or self.offScreen()) return;
        var col = self.col;
        while (col < self.frame_size.cols) : (col += 1) self.clearGlyph(self.index(self.row, col));
    }

    /// Fill the rest of the current row with explicit styled spaces without
    /// changing the logical cursor or current drawing style.
    pub fn fillToEndOfLine(self: *Screen, style: Style) void {
        if (self.err != null or self.offScreen()) return;
        const saved_row = self.row;
        const saved_col = self.col;
        const saved_style = self.draw_style;
        while (self.col < self.frame_size.cols and self.err == null)
            self.putGlyph(" ", 1, style);
        self.row = saved_row;
        self.col = saved_col;
        self.draw_style = saved_style;
    }

    /// Leave the terminal cursor here when the frame is presented, and make
    /// it visible. A frame that never calls this leaves it hidden.
    pub fn showCursor(self: *Screen, row: u16, col: u16) void {
        self.cursor = .{ .row = row, .col = col };
    }

    /// Diff the logical frame against the last successful one and flush the
    /// resulting ANSI stream with one write.
    pub fn present(self: *Screen) Error!void {
        if (self.err) |e| return e;

        const same_size = self.front_valid and
            self.front_size.rows == self.frame_size.rows and
            self.front_size.cols == self.frame_size.cols;

        if (!same_size) {
            // The previous cell coordinates no longer describe the terminal.
            // Resizes are rare, and a one-time clear is both smaller and more
            // reliable than trying to translate the old grid.
            self.raw("\x1b[2J");
        }

        var row: u16 = 0;
        while (row < self.frame_size.rows) : (row += 1) self.emitChangedRow(row, same_size);

        if (self.cursor) |c| {
            if (c.row < self.frame_size.rows and c.col < self.frame_size.cols)
                self.print("\x1b[{d};{d}H\x1b[?25h", .{ c.row + 1, c.col + 1 });
        }
        if (self.synchronized_output) self.raw(end_sync);
        if (self.err) |e| return e;

        sys.writeAll(self.fd, self.buf.items) catch {
            // Part of the frame may already be on screen, so the front grid no
            // longer describes the terminal and cannot be diffed against.
            // Dropping it costs one full repaint; keeping it would corrupt
            // every later frame with no way back.
            self.front_valid = false;
            return error.WriteFailed;
        };

        // The terminal now matches the back grid. Swapping makes it the next
        // frame's immutable comparison image without copying any cells/text.
        std.mem.swap(std.ArrayList(Cell), &self.front, &self.back);
        std.mem.swap(std.ArrayList(u8), &self.front_text, &self.back_text);
        self.front_size = self.frame_size;
        self.front_valid = true;
    }

    /// Bytes written by the most recent frame. Primarily for tests.
    pub fn frame(self: *const Screen) []const u8 {
        return self.buf.items;
    }

    // --- logical frame construction --------------------------------------

    /// Also true before the first `begin()`, when `frame_size` is still zero
    /// and there is no grid to draw into.
    fn offScreen(self: *const Screen) bool {
        return self.row >= self.frame_size.rows or self.col >= self.frame_size.cols;
    }

    fn index(self: *const Screen, row: u16, col: u16) usize {
        return @as(usize, row) * @as(usize, self.frame_size.cols) + @as(usize, col);
    }

    fn writeClipped(self: *Screen, text: []const u8, style: Style) void {
        var clusters = unicode.text(text).graphemes().measured().iterator();
        while (clusters.next()) |span| {
            const bytes = text[span.start.value..span.end.value];
            if (span.columns == 0) {
                if (isAttachable(bytes)) self.appendCombining(bytes);
                continue;
            }

            const replacement = !span.renderable;
            const columns = span.columns;
            if (self.col >= self.frame_size.cols) return;
            const remaining = self.frame_size.cols - self.col;
            if (columns > remaining) {
                // Never leave a half-wide glyph at the right edge.
                self.putGlyph(" ", 1, style);
                return;
            }
            self.putGlyph(if (replacement) "?" else cappedCluster(bytes), columns, style);
            if (self.err != null) return;
        }
    }

    fn cappedCluster(bytes: []const u8) []const u8 {
        if (bytes.len <= max_cell_bytes) return bytes;
        var end: usize = 0;
        while (end < bytes.len) {
            const step = unicode.utf8.step(bytes[end..]);
            if (end + step.len > max_cell_bytes) break;
            end += step.len;
        }
        return bytes[0..end];
    }

    /// Preserve the long-standing behavior where a caller can write a base
    /// and its marks in separate calls, without ever appending controls or
    /// malformed input to an existing cell.
    fn isAttachable(bytes: []const u8) bool {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const step = unicode.utf8.step(bytes[pos..]);
            pos += step.len;
            const cp = step.cp orelse return false;
            if (cp < 0x20 or cp == 0x7f or unicode.text(bytes[pos - step.len .. pos]).width() != 0)
                return false;
        }
        return bytes.len > 0;
    }

    fn putGlyph(self: *Screen, bytes: []const u8, columns: u2, style: Style) void {
        const head = self.index(self.row, self.col);
        self.clearGlyph(head);
        if (columns == 2) self.clearGlyph(head + 1);

        const off = self.appendText(bytes) orelse return;
        self.back.items[head] = .{
            .text_off = off,
            .text_len = bytes.len,
            .style = style,
            .columns = columns,
        };
        if (columns == 2) {
            self.back.items[head + 1] = .{
                .style = style,
                .columns = 0,
                .continuation = true,
            };
        }
        self.col += columns;
    }

    fn appendCombining(self: *Screen, bytes: []const u8) void {
        // A zero-width mark combines with the glyph immediately before the
        // terminal cursor. With no preceding glyph there is no stable cell to
        // retain it in, and terminals do not agree on how to display it.
        if (self.col == 0) return;

        var cell_index = self.index(self.row, self.col - 1);
        if (self.back.items[cell_index].continuation) cell_index -= 1;
        var cell = &self.back.items[cell_index];
        if (cell.isBlank()) return;

        const old_off = cell.text_off;
        const old_len = cell.text_len;
        if (old_len + bytes.len > max_cell_bytes) return;
        self.back_text.ensureUnusedCapacity(self.gpa, old_len + bytes.len) catch {
            self.err = error.OutOfMemory;
            return;
        };

        // Usually the glyph is already the arena tail, so only the combining
        // bytes need appending. Revisited cells are copied to a new contiguous
        // slice before the mark is added.
        if (old_off + old_len != self.back_text.items.len) {
            const new_off = self.back_text.items.len;
            const old = self.back_text.items[old_off..][0..old_len];
            self.back_text.appendSliceAssumeCapacity(old);
            cell = &self.back.items[cell_index];
            cell.text_off = new_off;
        }
        self.back_text.appendSliceAssumeCapacity(bytes);
        self.back.items[cell_index].text_len = old_len + bytes.len;
    }

    fn appendText(self: *Screen, bytes: []const u8) ?usize {
        const off = self.back_text.items.len;
        self.back_text.appendSlice(self.gpa, bytes) catch {
            self.err = error.OutOfMemory;
            return null;
        };
        return off;
    }

    fn clearGlyph(self: *Screen, at: usize) void {
        if (at >= self.back.items.len) return;
        var head = at;
        if (self.back.items[head].continuation and head > 0) head -= 1;
        const columns = self.back.items[head].columns;
        self.back.items[head] = Cell.blank;
        if (columns == 2 and head + 1 < self.back.items.len)
            self.back.items[head + 1] = Cell.blank;
    }

    // --- diff emission ----------------------------------------------------

    fn emitChangedRow(self: *Screen, row: u16, compare_front: bool) void {
        if (self.err != null or self.frame_size.cols == 0) return;
        const row_start = self.index(row, 0);
        const row_end = row_start + self.frame_size.cols;

        var first = row_start;
        while (first < row_end and !self.cellChanged(first, compare_front)) : (first += 1) {}
        if (first == row_end) return;

        // A changed continuation is always redrawn with its head.
        if (first > row_start and (self.back.items[first].continuation or
            (compare_front and self.front.items[first].continuation))) first -= 1;

        var last = row_end;
        while (last > first and !self.cellChanged(last - 1, compare_front)) : (last -= 1) {}
        if (last < row_end and (self.back.items[last].continuation or
            (compare_front and self.front.items[last].continuation))) last += 1;

        const first_col = first - row_start;
        self.print("\x1b[{d};{d}H", .{ row + 1, first_col + 1 });

        var at = first;
        while (at < last) {
            if (self.back.items[at].isBlank() and self.allBlank(at, row_end)) {
                // Erase uses the active background color. Reset first so a
                // deleted reversed/colored row becomes a true default blank.
                self.emitStyle(.{});
                self.raw("\x1b[K");
                return;
            }

            const cell = self.back.items[at];
            if (cell.continuation) {
                at += 1;
                continue;
            }
            if (cell.isBlank()) {
                self.emitStyle(.{});
                self.raw(" ");
                at += 1;
                continue;
            }

            if (self.isSpace(at)) {
                const run = self.spaceRun(at, last);
                self.emitStyle(cell.style);
                self.emitSpaces(run);
                at += run;
                continue;
            }

            self.emitStyle(cell.style);
            self.raw(self.back_text.items[cell.text_off..][0..cell.text_len]);
            at += cell.columns;
        }
    }

    /// A run of spaces in the style already emitted.
    ///
    /// REP repeats the preceding graphic character with its rendition, so one
    /// literal space plus CSI Ps b is smaller than a long styled-space run and
    /// keeps its attributes. It is off by default because a terminal that does
    /// not implement REP drops the sequence silently, leaving a styled
    /// background truncated to the width of its text — a visible defect traded
    /// for roughly 90 bytes on a frame that was never limited by bytes.
    fn emitSpaces(self: *Screen, run: usize) void {
        if (self.repeat_sequences) {
            const repeats = run - 1;
            // 4 covers ESC [ b plus the literal space that REP repeats.
            if (run > 4 + decimalDigits(repeats)) {
                self.raw(" ");
                self.print("\x1b[{d}b", .{repeats});
                return;
            }
        }
        const spaces = " " ** 32;
        var left = run;
        while (left > 0) {
            const n = @min(left, spaces.len);
            self.raw(spaces[0..n]);
            left -= n;
        }
    }

    fn cellChanged(self: *const Screen, at: usize, compare_front: bool) bool {
        const back = self.back.items[at];
        if (!compare_front) return !back.isBlank();
        const front = self.front.items[at];
        if (back.continuation != front.continuation or
            back.columns != front.columns or
            !std.meta.eql(back.style, front.style) or
            back.text_len != front.text_len) return true;
        if (back.text_len == 0) return false;
        return !std.mem.eql(
            u8,
            self.back_text.items[back.text_off..][0..back.text_len],
            self.front_text.items[front.text_off..][0..front.text_len],
        );
    }

    fn allBlank(self: *const Screen, from: usize, end: usize) bool {
        for (self.back.items[from..end]) |cell| if (!cell.isBlank()) return false;
        return true;
    }

    fn isSpace(self: *const Screen, at: usize) bool {
        const cell = self.back.items[at];
        return !cell.continuation and cell.columns == 1 and cell.text_len == 1 and
            self.back_text.items[cell.text_off] == ' ';
    }

    fn spaceRun(self: *const Screen, from: usize, end: usize) usize {
        const style = self.back.items[from].style;
        var at = from;
        while (at < end and self.isSpace(at) and
            std.meta.eql(style, self.back.items[at].style)) : (at += 1)
        {}
        return at - from;
    }

    fn decimalDigits(value: usize) usize {
        var n = value;
        var digits: usize = 1;
        while (n >= 10) : (n /= 10) digits += 1;
        return digits;
    }

    fn emitStyle(self: *Screen, style: Style) void {
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
            .ansi => |n| self.print("\x1b[{d}m", .{
                if (n < 8) base + @as(u8, n) else base + 60 + (@as(u8, n) - 8),
            }),
            .indexed => |n| self.print("\x1b[{d};5;{d}m", .{ ext, n }),
            .rgb => |v| self.print("\x1b[{d};2;{d};{d};{d}m", .{ ext, v.r, v.g, v.b }),
        }
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
};
