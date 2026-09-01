//! Allocation-free cursor and scroll-offset arithmetic for list views.

pub const Viewport = struct {
    cursor: usize = 0,
    offset: usize = 0,

    pub const Range = struct { start: usize, end: usize };

    /// Clamp state to the current item count and keep the cursor visible with
    /// the smallest necessary offset adjustment.
    pub fn normalize(self: *Viewport, item_count: usize, visible_rows: usize) void {
        if (item_count == 0) {
            self.cursor = 0;
            self.offset = 0;
            return;
        }

        self.cursor = @min(self.cursor, item_count - 1);
        if (visible_rows == 0) {
            self.offset = self.cursor;
            return;
        }
        if (item_count <= visible_rows) {
            self.offset = 0;
            return;
        }

        const max_offset = item_count - visible_rows;
        self.offset = @min(self.offset, max_offset);
        if (self.cursor < self.offset) {
            self.offset = self.cursor;
        } else if (self.cursor - self.offset >= visible_rows) {
            self.offset = self.cursor - visible_rows + 1;
        }
    }

    pub fn setCursor(
        self: *Viewport,
        index: usize,
        item_count: usize,
        visible_rows: usize,
    ) void {
        self.cursor = index;
        self.normalize(item_count, visible_rows);
    }

    /// Move without wrapping or overflowing, including for min/max `isize`.
    pub fn move(
        self: *Viewport,
        delta: isize,
        item_count: usize,
        visible_rows: usize,
    ) void {
        self.normalize(item_count, visible_rows);
        if (item_count == 0) return;

        if (delta < 0) {
            // `-minInt(isize)` is not representable. Offset by one before
            // negating, then restore that unit in unsigned space.
            const almost: usize = @intCast(-(delta + 1));
            self.cursor -|= almost + 1;
        } else {
            self.cursor +|= @intCast(delta);
        }
        self.normalize(item_count, visible_rows);
    }

    /// Return the normalized, end-exclusive slice visible at this height.
    pub fn visibleRange(
        self: Viewport,
        item_count: usize,
        visible_rows: usize,
    ) Range {
        var normalized = self;
        normalized.normalize(item_count, visible_rows);
        if (item_count == 0) return .{ .start = 0, .end = 0 };
        if (visible_rows == 0)
            return .{ .start = normalized.offset, .end = normalized.offset };
        return .{
            .start = normalized.offset,
            .end = @min(normalized.offset + visible_rows, item_count),
        };
    }
};
