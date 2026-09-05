//! Allocation-free grapheme-safe terminal wrapping.
const std = @import("std");
const unicode = @import("zunic");

pub const Mode = enum { cell, word };
pub const Kind = enum { text, replacement };
pub const Fragment = struct {
    start: usize,
    end: usize,
    columns: usize,
    kind: Kind,
};

pub const Error = error{ZeroColumns};

pub fn iterator(text: []const u8, columns: usize, mode: Mode) Error!Iterator {
    if (columns == 0) return error.ZeroColumns;
    return .{
        .text = text,
        .columns = columns,
        .mode = mode,
        .breaks = unicode.line_break.iterator(text),
    };
}

pub const Iterator = struct {
    text: []const u8,
    columns: usize,
    mode: Mode,
    pos: usize = 0,
    emitted_empty_input: bool = false,
    final_empty: bool = false,
    // This is advanced only as the wrapper commits text. A saved copy lets
    // word wrapping roll back to its last legal break without re-scanning.
    breaks: unicode.line_break.Iterator,

    pub fn next(self: *Iterator) ?Fragment {
        if (self.pos >= self.text.len) {
            if (self.final_empty or (!self.emitted_empty_input and self.text.len == 0)) {
                self.final_empty = false;
                self.emitted_empty_input = true;
                return .{ .start = self.text.len, .end = self.text.len, .columns = 0, .kind = .text };
            }
            return null;
        }

        var clusters = unicode.grapheme.iterator(self.text[self.pos..]);
        const line_start = self.pos;
        var start = line_start;
        var end = line_start;
        var used: usize = 0;
        var allowed_end: ?usize = null;
        var allowed_columns: usize = 0;
        var breaks = self.breaks;
        var allowed_breaks: ?unicode.line_break.Iterator = null;

        while (clusters.next()) |relative| {
            const span = .{ .start = line_start + relative.start, .end = line_start + relative.end };
            const bytes = self.text[span.start..span.end];
            if (isMandatoryBreak(bytes)) {
                self.pos = span.end;
                if (used == 0) {
                    self.final_empty = self.pos == self.text.len;
                    return .{ .start = start, .end = start, .columns = 0, .kind = .text };
                }
                self.final_empty = self.pos == self.text.len;
                return .{ .start = start, .end = end, .columns = used, .kind = .text };
            }

            const measure = unicode.width.measureCluster(bytes);
            const cluster_columns: usize = if (measure.columns == 3) 1 else measure.columns;
            if (measure.columns == 0) {
                // Never expose leading orphan marks: a separate Screen.write
                // could otherwise attach them to a caller's preceding cell.
                if (used == 0) start = span.end;
                end = span.end;
                self.pos = span.end;
                continue;
            }
            if (used + cluster_columns > self.columns) {
                if (used == 0) {
                    self.pos = span.end;
                    return .{ .start = span.start, .end = span.end, .columns = 1, .kind = .replacement };
                }
                if (self.mode == .word) if (allowed_end) |break_end| {
                    self.pos = break_end;
                    self.breaks = allowed_breaks.?;
                    return .{ .start = start, .end = break_end, .columns = allowed_columns, .kind = .text };
                };
                self.pos = end;
                return .{ .start = start, .end = end, .columns = used, .kind = .text };
            }

            used += cluster_columns;
            end = span.end;
            self.pos = span.end;
            if (self.mode == .word) {
                if (opportunityAt(&breaks, end) == .allowed) {
                    allowed_end = end;
                    allowed_columns = used;
                    allowed_breaks = breaks;
                }
                self.breaks = breaks;
            }
            if (used == self.columns) {
                // Consume an adjacent line terminator so an exact-width line
                // remains one row; only a trailing terminator adds its final
                // explicit empty row.
                var following = unicode.grapheme.iterator(self.text[self.pos..]);
                if (following.next()) |next_span| {
                    const next_bytes = self.text[self.pos + next_span.start .. self.pos + next_span.end];
                    if (isMandatoryBreak(next_bytes)) {
                        self.pos += next_span.end;
                        self.final_empty = self.pos == self.text.len;
                    }
                }
                return .{ .start = start, .end = end, .columns = used, .kind = .text };
            }
        }

        self.pos = self.text.len;
        return .{ .start = start, .end = end, .columns = used, .kind = .text };
    }
};

fn isMandatoryBreak(bytes: []const u8) bool {
    return std.mem.eql(u8, bytes, "\n") or
        std.mem.eql(u8, bytes, "\r") or
        std.mem.eql(u8, bytes, "\r\n") or
        std.mem.eql(u8, bytes, "\xc2\x85") or // NEL
        std.mem.eql(u8, bytes, "\xe2\x80\xa8") or // LS
        std.mem.eql(u8, bytes, "\xe2\x80\xa9"); // PS
}

/// Return the UAX #14 opportunity immediately after `offset`. The iterator
/// reports boundaries before scalars, so this consumes through the next
/// scalar's start (or the input's final boundary).
fn opportunityAt(breaks: *unicode.line_break.Iterator, offset: usize) unicode.line_break.Opportunity {
    while (breaks.next()) |boundary| {
        if (boundary.offset >= offset) {
            return if (boundary.offset == offset) boundary.opportunity else .prohibited;
        }
    }
    return .prohibited;
}
