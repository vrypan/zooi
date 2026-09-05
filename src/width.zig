//! Display width: how many terminal columns a codepoint or string occupies.
//!
//! Terminal width is not UTF-8 byte length. `é` is two bytes and one column,
//! `世` is three bytes and two columns, and a combining accent is two bytes and
//! no columns at all. Clipping by byte length wraps a line, shifts every row
//! below it, and produces no error to search for — which is why every write in
//! screen.zig measures through this module.
//!
//! This compatibility facade keeps the original codepoint-oriented entry
//! points available. New layout and rendering code use `unicode.width`, whose
//! cluster policy is also used by `Screen`.

const unicode = @import("unicode/root.zig");

/// Columns a codepoint occupies: 0 for combining marks and format characters,
/// 2 for East Asian wide and fullwidth, 1 otherwise.
pub fn codepointWidth(cp: u21) u2 {
    return unicode.width.codepointWidth(cp);
}

/// Columns a UTF-8 string occupies after the same filtering and grapheme
/// policy as `Screen`. Invalid bytes and controls take no cells, so text that
/// is measured here and then drawn remains aligned.
pub fn strWidth(bytes: []const u8) usize {
    return unicode.width.textWidth(bytes);
}

pub const Step = struct {
    /// Bytes consumed. Always at least 1.
    len: usize,
    /// Columns occupied.
    width: u2,
    /// The decoded codepoint, or null for a byte that is not part of a
    /// well-formed sequence. The screen uses this to recognise and drop
    /// control characters.
    cp: ?u21,
};

/// One codepoint's worth of progress through a byte slice.
///
/// Anything that is not a well-formed sequence advances exactly one byte and
/// counts one column. That keeps every caller's loop monotonic: a truncated or
/// invalid sequence can never stall it or read past the end.
///
/// This rather than a "longest prefix that fits" helper, because the screen
/// has to sanitise and measure in the same pass — it drops control bytes while
/// counting columns, and a function returning only a prefix length cannot
/// express that.
pub fn step(bytes: []const u8) Step {
    const s = unicode.utf8.step(bytes);
    return .{ .len = s.len, .width = if (s.cp) |cp| codepointWidth(cp) else 1, .cp = s.cp };
}
