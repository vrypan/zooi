//! Allocation-free grapheme-safe terminal wrapping.
const unicode = @import("unicode/root.zig");

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
    return .{ .text = text, .columns = columns, .mode = mode };
}

pub const Iterator = struct {
    text: []const u8,
    columns: usize,
    mode: Mode,
    pos: usize = 0,
    emitted_empty_input: bool = false,
    final_empty: bool = false,

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
                    return .{ .start = start, .end = break_end, .columns = allowed_columns, .kind = .text };
                };
                self.pos = end;
                return .{ .start = start, .end = end, .columns = used, .kind = .text };
            }

            used += cluster_columns;
            end = span.end;
            self.pos = span.end;
            if (self.mode == .word and unicode.line_break.after(bytes) == .allowed) {
                allowed_end = end;
                allowed_columns = used;
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
    return bytes.len > 0 and (bytes[0] == '\n' or (bytes[0] == '\r' and bytes.len > 1 and bytes[1] == '\n'));
}
