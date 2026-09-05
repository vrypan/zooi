const std = @import("std");
const RowIndex = @import("row_index.zig").RowIndex;
const VariableViewport = @import("variable_viewport.zig").VariableViewport;

test "variable viewport keeps a focused row visible" {
    var storage: [4]usize = undefined;
    const index = try RowIndex.build(&.{ 2, 1, 4 }, &storage);
    var view: VariableViewport = .{};
    view.moveRows(5, index, 2);
    try std.testing.expectEqual(@as(usize, 2), view.cursor);
    try std.testing.expectEqual(@as(usize, 2), view.row_in_item);
    try std.testing.expectEqual(@as(usize, 4), view.offset);
    view.moveItems(-1, index, 2);
    try std.testing.expectEqual(@as(usize, 1), view.cursor);
    try std.testing.expectEqual(@as(usize, 0), view.row_in_item);
}

test "variable viewport pages a tall item by visual rows" {
    var storage: [2]usize = undefined;
    const index = try RowIndex.build(&.{10}, &storage);
    var view: VariableViewport = .{};
    view.page(.down, index, 3);
    try std.testing.expectEqual(@as(usize, 3), view.row_in_item);
    view.page(.up, index, 3);
    try std.testing.expectEqual(@as(usize, 0), view.row_in_item);
}
