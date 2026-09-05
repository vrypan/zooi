//! Prefix-indexed mapping between logical items and their visual rows.
const std = @import("std");

pub const RowIndex = struct {
    offsets: []const usize,

    pub const Error = error{ InsufficientStorage, ZeroHeight, Overflow };
    pub const Range = struct { start: usize, end: usize };
    pub const Position = struct { item: usize, row_in_item: usize };
    pub const VisibleItem = struct {
        item: usize,
        first_row: usize,
        row_count: usize,
        screen_row: usize,
    };

    /// Build into caller-owned storage. The returned index borrows `storage`;
    /// keep it alive and unchanged for as long as the index is used.
    pub fn build(heights: []const usize, storage: []usize) Error!RowIndex {
        if (storage.len < heights.len + 1) return error.InsufficientStorage;
        var sum: usize = 0;
        storage[0] = 0;
        for (heights, 0..) |height, item| {
            if (height == 0) return error.ZeroHeight;
            sum = std.math.add(usize, sum, height) catch return error.Overflow;
            storage[item + 1] = sum;
        }
        return .{ .offsets = storage[0 .. heights.len + 1] };
    }

    pub fn itemCount(self: RowIndex) usize {
        return self.offsets.len - 1;
    }

    pub fn totalRows(self: RowIndex) usize {
        return self.offsets[self.offsets.len - 1];
    }

    pub fn itemRows(self: RowIndex, item: usize) ?Range {
        if (item >= self.itemCount()) return null;
        return .{ .start = self.offsets[item], .end = self.offsets[item + 1] };
    }

    pub fn locate(self: RowIndex, row: usize) ?Position {
        if (row >= self.totalRows()) return null;
        var lo: usize = 0;
        var hi = self.itemCount();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.offsets[mid + 1] <= row) lo = mid + 1 else hi = mid;
        }
        return .{ .item = lo, .row_in_item = row - self.offsets[lo] };
    }

    pub fn visible(self: RowIndex, offset: usize, height: usize) VisibleIterator {
        const start = @min(offset, self.totalRows());
        const end = start +| height;
        return .{ .index = self, .start = start, .end = @min(end, self.totalRows()) };
    }

    pub const VisibleIterator = struct {
        index: RowIndex,
        start: usize,
        end: usize,
        next_item: ?usize = null,

        pub fn next(self: *VisibleIterator) ?VisibleItem {
            if (self.start >= self.end) return null;
            const item = self.next_item orelse self.index.locate(self.start).?.item;
            if (item >= self.index.itemCount()) return null;
            const rows = self.index.itemRows(item).?;
            const from = @max(rows.start, self.start);
            const to = @min(rows.end, self.end);
            self.next_item = item + 1;
            if (from >= to) return null;
            return .{
                .item = item,
                .first_row = from - rows.start,
                .row_count = to - from,
                .screen_row = from - self.start,
            };
        }
    };
};
