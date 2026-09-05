const std = @import("std");
const RowIndex = @import("row_index.zig").RowIndex;

test "row index maps rows and clipped visibility" {
    var storage: [4]usize = undefined;
    const index = try RowIndex.build(&.{ 2, 1, 4 }, &storage);
    try std.testing.expectEqual(@as(usize, 3), index.itemCount());
    try std.testing.expectEqual(@as(usize, 7), index.totalRows());
    try std.testing.expectEqual(RowIndex.Position{ .item = 2, .row_in_item = 3 }, index.locate(6).?);
    try std.testing.expect(index.locate(7) == null);

    var visible = index.visible(1, 4);
    try std.testing.expectEqual(RowIndex.VisibleItem{ .item = 0, .first_row = 1, .row_count = 1, .screen_row = 0 }, visible.next().?);
    try std.testing.expectEqual(RowIndex.VisibleItem{ .item = 1, .first_row = 0, .row_count = 1, .screen_row = 1 }, visible.next().?);
    try std.testing.expectEqual(RowIndex.VisibleItem{ .item = 2, .first_row = 0, .row_count = 2, .screen_row = 2 }, visible.next().?);
    try std.testing.expect(visible.next() == null);
}

test "row index validates caller storage and heights" {
    var tiny: [1]usize = undefined;
    try std.testing.expectError(error.InsufficientStorage, RowIndex.build(&.{1}, &tiny));
    var storage: [2]usize = undefined;
    try std.testing.expectError(error.ZeroHeight, RowIndex.build(&.{0}, &storage));
    var overflow_storage: [3]usize = undefined;
    try std.testing.expectError(error.Overflow, RowIndex.build(&.{ std.math.maxInt(usize), 1 }, &overflow_storage));
}
