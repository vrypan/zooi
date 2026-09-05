//! Navigation state for items whose rendered heights differ.
const RowIndex = @import("row_index.zig").RowIndex;

pub const VariableViewport = struct {
    cursor: usize = 0,
    row_in_item: usize = 0,
    offset: usize = 0,

    pub const Direction = enum { up, down };

    pub fn normalize(self: *VariableViewport, index: RowIndex, height: usize) void {
        if (index.itemCount() == 0) {
            self.* = .{};
            return;
        }
        self.cursor = @min(self.cursor, index.itemCount() - 1);
        const rows = index.itemRows(self.cursor).?;
        self.row_in_item = @min(self.row_in_item, rows.end - rows.start - 1);
        const focused = rows.start + self.row_in_item;
        if (height == 0) {
            self.offset = focused;
            return;
        }
        self.offset = @min(self.offset, index.totalRows() -| height);
        if (focused < self.offset) {
            self.offset = focused;
        } else if (focused - self.offset >= height) {
            self.offset = focused - height + 1;
        }
    }

    pub fn setCursor(self: *VariableViewport, item: usize, index: RowIndex, height: usize) void {
        self.cursor = item;
        self.row_in_item = 0;
        self.normalize(index, height);
    }

    pub fn moveItems(self: *VariableViewport, delta: isize, index: RowIndex, height: usize) void {
        self.normalize(index, height);
        if (index.itemCount() == 0) return;
        const old = self.cursor;
        if (delta < 0) {
            const magnitude: usize = @intCast(-(delta + 1));
            self.cursor -|= magnitude + 1;
        } else {
            self.cursor +|= @intCast(delta);
        }
        self.cursor = @min(self.cursor, index.itemCount() - 1);
        if (self.cursor != old) self.row_in_item = 0;
        self.normalize(index, height);
    }

    pub fn moveRows(self: *VariableViewport, delta: isize, index: RowIndex, height: usize) void {
        self.normalize(index, height);
        if (index.itemCount() == 0) return;
        const current = index.itemRows(self.cursor).?.start + self.row_in_item;
        var target = current;
        if (delta < 0) {
            const magnitude: usize = @intCast(-(delta + 1));
            target -|= magnitude + 1;
        } else {
            target +|= @intCast(delta);
        }
        target = @min(target, index.totalRows() - 1);
        const position = index.locate(target).?;
        self.cursor = position.item;
        self.row_in_item = position.row_in_item;
        self.normalize(index, height);
    }

    pub fn page(self: *VariableViewport, direction: Direction, index: RowIndex, height: usize) void {
        const amount = @max(height, 1);
        self.normalize(index, height);
        if (index.itemCount() == 0) return;
        const current = index.itemRows(self.cursor).?.start + self.row_in_item;
        const target = switch (direction) {
            .up => current -| amount,
            .down => @min(current +| amount, index.totalRows() - 1),
        };
        const position = index.locate(target).?;
        self.cursor = position.item;
        self.row_in_item = position.row_in_item;
        self.normalize(index, height);
    }

    pub fn visibleItems(self: VariableViewport, index: RowIndex, height: usize) RowIndex.VisibleIterator {
        var normalized = self;
        normalized.normalize(index, height);
        return index.visible(normalized.offset, height);
    }
};
