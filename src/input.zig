//! Terminal bytes to keys.
//!
//! A `read()` is not one key event. One read can deliver half an arrow key,
//! three keypresses, or the first two bytes of a three-byte character, so the
//! parser is a resumable state machine over a byte stream rather than a
//! function of one buffer.
//!
//! ## The escape ambiguity
//!
//! `ESC` alone is the Escape key; `ESC [ A` is Up. The parser cannot tell
//! which it is without knowing whether more bytes are coming, and only the
//! event loop knows that. The contract is three calls:
//!
//!   * `next()` returns null when it cannot yet decide.
//!   * `awaitingEscape()` says whether waiting could possibly help.
//!   * `timeout()` forces the decision after the loop's escape timeout.
//!
//! Nothing else in zooi knows about this ambiguity.

const std = @import("std");

pub const Key = union(enum) {
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,

    shift_up,
    shift_down,

    enter,
    escape,
    backspace,
    delete,

    /// A printable character. Control bytes never arrive as `character`, so a
    /// prompt can append this to a buffer with no filtering.
    character: u21,

    ctrl_c,
};

const esc = 0x1b;

/// Fixed and inline: no allocator, so a test is `var p: Parser = .{};`.
/// 32 bytes is far more than any real key sequence.
pub const Parser = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,

    /// Append bytes read from the terminal.
    ///
    /// Returns false if they would overflow the buffer, in which case the
    /// parser is reset and the bytes are dropped. A well-formed terminal never
    /// sends a 32-byte key, so this means the stream is not what we think it
    /// is, and resetting resynchronises rather than wedging.
    pub fn feed(self: *Parser, bytes: []const u8) bool {
        if (self.len + bytes.len > self.buf.len) {
            self.len = 0;
            return false;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        return true;
    }

    /// Pop the next complete key, or null if more bytes are needed.
    ///
    /// Null does not distinguish "nothing pending" from "waiting on an escape
    /// sequence" — ask `awaitingEscape` for that.
    pub fn next(self: *Parser) ?Key {
        while (true) {
            switch (scan(self.buf[0..self.len])) {
                .empty, .incomplete => return null,
                .drop => |n| self.consume(n),
                .found => |f| {
                    self.consume(f.len);
                    return f.key;
                },
            }
        }
    }

    /// True when the buffer holds an incomplete sequence beginning with ESC.
    /// The event loop arms its escape timeout exactly while this is true, and
    /// blocks indefinitely otherwise.
    pub fn awaitingEscape(self: *const Parser) bool {
        var off: usize = 0;
        while (true) {
            switch (scan(self.buf[off..self.len])) {
                .empty, .found => return false,
                .incomplete => return self.buf[off] == esc,
                .drop => |n| off += n,
            }
        }
    }

    /// Resolve a pending ESC as a literal Escape keypress. Called by the loop
    /// when the escape timeout expires. Returns null if nothing was pending.
    ///
    /// Only the ESC itself is consumed. Anything after it stays in the buffer
    /// and is read as literal input, which is what a user who pressed Escape
    /// and then typed would expect.
    pub fn timeout(self: *Parser) ?Key {
        if (self.len > 0 and self.buf[0] == esc) {
            self.consume(1);
            return .escape;
        }
        return null;
    }

    fn consume(self: *Parser, n: usize) void {
        std.debug.assert(n <= self.len);
        std.mem.copyForwards(u8, self.buf[0 .. self.len - n], self.buf[n..self.len]);
        self.len -= n;
    }
};

const Scan = union(enum) {
    /// Nothing buffered.
    empty,
    /// A prefix of something valid; more bytes may complete it.
    incomplete,
    /// Consume this many bytes and produce nothing.
    drop: usize,
    found: struct { key: Key, len: usize },
};

fn found(key: Key, len: usize) Scan {
    return .{ .found = .{ .key = key, .len = len } };
}

/// Pure: a function of the buffered bytes, so it is testable on its own and
/// cannot depend on parser state that a test would have to construct.
fn scan(bytes: []const u8) Scan {
    if (bytes.len == 0) return .empty;
    const b = bytes[0];

    if (b == esc) return scanEscape(bytes);

    switch (b) {
        0x03 => return found(.ctrl_c, 1),
        '\r', '\n' => return found(.enter, 1),
        0x7f, 0x08 => return found(.backspace, 1),
        else => {},
    }

    // Every other control byte is dropped, so `character` means printable
    // text and a prompt never has to filter it.
    if (b < 0x20) return .{ .drop = 1 };

    return scanUtf8(bytes);
}

fn scanUtf8(bytes: []const u8) Scan {
    // An invalid lead byte is dropped immediately rather than treated as
    // "need more": waiting on it would wedge the parser forever on one bad
    // byte. A valid lead with too few bytes behind it is genuinely
    // incomplete and resolves on the next read.
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .drop = 1 };
    if (bytes.len < n) return .incomplete;
    const cp = std.unicode.utf8Decode(bytes[0..n]) catch return .{ .drop = 1 };
    return found(.{ .character = cp }, n);
}

fn scanEscape(bytes: []const u8) Scan {
    if (bytes.len < 2) return .incomplete;
    return switch (bytes[1]) {
        '[' => scanCsi(bytes),
        'O' => scanSs3(bytes),
        // ESC followed by anything else. Alt+key and "Escape then key" are
        // indistinguishable here; v1 has no Alt bindings, so this is Escape
        // and the following byte is read as itself on the next call.
        else => found(.escape, 1),
    };
}

/// `ESC [` params final, where params are 0x30-0x3F, optional intermediates
/// are 0x20-0x2F, and the final byte is 0x40-0x7E.
fn scanCsi(bytes: []const u8) Scan {
    var i: usize = 2;
    while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) i += 1;
    const params_end = i;
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) i += 1;
    if (i >= bytes.len) return .incomplete;

    const final = bytes[i];
    if (final < 0x40 or final > 0x7e) return .{ .drop = 1 };

    const total = i + 1;
    const params = bytes[2..params_end];

    if (lookupCsi(params, final)) |k| return found(k, total);

    // Structurally valid but not a key we bind — bracketed paste markers, for
    // instance. Swallow it whole: leaving it would type `200~` into a prompt.
    return .{ .drop = total };
}

fn lookupCsi(params: []const u8, final: u8) ?Key {
    const eq = std.mem.eql;

    if (params.len == 0) {
        return switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => null,
        };
    }

    // Shift is modifier 2. Only the two the spec's selection bindings need.
    if (eq(u8, params, "1;2")) {
        return switch (final) {
            'A' => .shift_up,
            'B' => .shift_down,
            else => null,
        };
    }

    if (final == '~') {
        // xterm, the Linux console, and rxvt disagree about Home and End, so
        // all the spellings map.
        if (eq(u8, params, "1") or eq(u8, params, "7")) return .home;
        if (eq(u8, params, "4") or eq(u8, params, "8")) return .end;
        if (eq(u8, params, "3")) return .delete;
        if (eq(u8, params, "5")) return .page_up;
        if (eq(u8, params, "6")) return .page_down;
    }

    return null;
}

/// `ESC O` final. Sent instead of CSI once cursor-key application mode is on,
/// which zooi never enables but a multiplexer may leave set.
fn scanSs3(bytes: []const u8) Scan {
    if (bytes.len < 3) return .incomplete;
    const k: ?Key = switch (bytes[2]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => null,
    };
    return if (k) |key| found(key, 3) else .{ .drop = 3 };
}
