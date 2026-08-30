//! Display width: how many terminal columns a codepoint or string occupies.
//!
//! Terminal width is not UTF-8 byte length. `é` is two bytes and one column,
//! `世` is three bytes and two columns, and a combining accent is two bytes and
//! no columns at all. Clipping by byte length wraps a line, shifts every row
//! below it, and produces no error to search for — which is why every write in
//! screen.zig measures through this module.
//!
//! **Scope.** Width is decided per codepoint. Grapheme clusters, ZWJ emoji
//! sequences, regional-indicator flags, and variation selectors are out of
//! scope: a family emoji built from several people and ZWJs measures as the sum
//! of its parts and will render wrong. That is the documented v1 boundary, not
//! an oversight.

const std = @import("std");
const table = @import("width_table.zig");

/// Columns a codepoint occupies: 0 for combining marks and format characters,
/// 2 for East Asian wide and fullwidth, 1 otherwise.
pub fn codepointWidth(cp: u21) u2 {
    // Fast path: ASCII printables are the overwhelming majority of what a
    // terminal application draws, and none of them are in either table.
    if (cp < 0x300) return 1;
    if (inRanges(&table.zero_width, cp)) return 0;
    if (inRanges(&table.wide, cp)) return 2;
    return 1;
}

fn inRanges(ranges: []const table.Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// Columns a UTF-8 string occupies. Invalid bytes count as one column each,
/// matching what a terminal does with them: a journal can contain arbitrary
/// bytes from arbitrary programs, and a measurement that can fail would turn
/// every render into an error path for no benefit.
pub fn strWidth(bytes: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const step = decode(bytes[i..]);
        total += step.width;
        i += step.len;
    }
    return total;
}

pub const Fit = struct {
    /// Bytes of the prefix that fits.
    len: usize,
    /// Columns that prefix actually occupies. May be `limit - 1` when a wide
    /// character was excluded for straddling the edge.
    width: usize,
};

/// The longest prefix of `bytes` fitting in `limit` columns.
///
/// A wide character that would straddle the limit is excluded rather than
/// half-drawn, so the caller must pad the reported width out to the limit if
/// it needs the column filled. Returning the length as well as the width
/// spares every caller from re-measuring.
pub fn fitPrefix(bytes: []const u8, limit: usize) Fit {
    var used: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const step = decode(bytes[i..]);
        if (used + step.width > limit) break;
        used += step.width;
        i += step.len;
    }
    return .{ .len = i, .width = used };
}

const Step = struct { len: usize, width: u2 };

/// One codepoint's worth of progress through a byte slice.
///
/// Anything that is not a well-formed sequence advances exactly one byte and
/// counts one column. That keeps the caller's loop monotonic: a truncated or
/// invalid sequence can never stall it or read past the end.
fn decode(bytes: []const u8) Step {
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .len = 1, .width = 1 };
    if (n > bytes.len) return .{ .len = 1, .width = 1 };
    const cp = std.unicode.utf8Decode(bytes[0..n]) catch return .{ .len = 1, .width = 1 };
    return .{ .len = n, .width = codepointWidth(cp) };
}
