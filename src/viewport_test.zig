const std = @import("std");
const Viewport = @import("viewport.zig").Viewport;

const expectEqual = std.testing.expectEqual;

fn expectState(view: Viewport, cursor: usize, offset: usize) !void {
    try expectEqual(cursor, view.cursor);
    try expectEqual(offset, view.offset);
}

test "an empty list always resets state and returns an empty range" {
    var view: Viewport = .{ .cursor = 99, .offset = 88 };
    view.normalize(0, 5);
    try expectState(view, 0, 0);
    view.setCursor(42, 0, 5);
    try expectState(view, 0, 0);
    view.move(std.math.maxInt(isize), 0, 5);
    try expectState(view, 0, 0);
    try expectEqual(Viewport.Range{ .start = 0, .end = 0 }, view.visibleRange(0, 5));
}

test "a one-item list stays at its only item" {
    var view: Viewport = .{};
    view.setCursor(100, 1, 4);
    try expectState(view, 0, 0);
    view.move(-100, 1, 4);
    try expectState(view, 0, 0);
}

test "movement clamps at both ends" {
    var view: Viewport = .{};
    view.move(-1, 10, 4);
    try expectState(view, 0, 0);
    view.move(100, 10, 4);
    try expectState(view, 9, 6);
    view.move(1, 10, 4);
    try expectState(view, 9, 6);
}

test "movement inside the viewport preserves the offset" {
    var view: Viewport = .{ .cursor = 5, .offset = 3 };
    view.move(1, 20, 5);
    try expectState(view, 6, 3);
    view.move(-2, 20, 5);
    try expectState(view, 4, 3);
}

test "crossing a viewport edge makes the minimal offset change" {
    var view: Viewport = .{ .cursor = 6, .offset = 3 };
    view.move(1, 20, 4);
    try expectState(view, 7, 4);
    view.setCursor(3, 20, 4);
    try expectState(view, 3, 3);
}

test "a list shorter than the viewport resets offset" {
    var view: Viewport = .{ .cursor = 3, .offset = 3 };
    view.normalize(4, 10);
    try expectState(view, 3, 0);
}

test "shrinking the list clamps old cursor and offset" {
    var view: Viewport = .{ .cursor = 90, .offset = 80 };
    view.normalize(7, 3);
    try expectState(view, 6, 4);
}

test "changing visible rows retains a visible cursor" {
    var view: Viewport = .{ .cursor = 8, .offset = 5 };
    view.normalize(20, 8);
    try expectState(view, 8, 5);
    view.normalize(20, 2);
    try expectState(view, 8, 7);
    view.normalize(20, 10);
    try expectState(view, 8, 7);
}

test "zero visible rows recover at a later nonzero height" {
    var view: Viewport = .{ .cursor = 7, .offset = 2 };
    view.normalize(20, 0);
    try expectState(view, 7, 7);
    try expectEqual(Viewport.Range{ .start = 7, .end = 7 }, view.visibleRange(20, 0));
    view.normalize(20, 4);
    try expectState(view, 7, 7);
}

test "visible range is end-exclusive and bounded" {
    const view: Viewport = .{ .cursor = 9, .offset = 8 };
    try expectEqual(Viewport.Range{ .start = 7, .end = 10 }, view.visibleRange(10, 3));
    try expectEqual(Viewport.Range{ .start = 0, .end = 2 }, view.visibleRange(2, 50));
}

test "extreme deltas clamp without overflow" {
    var view: Viewport = .{ .cursor = 5, .offset = 3 };
    view.move(std.math.maxInt(isize), 10, 4);
    try expectState(view, 9, 6);
    view.move(std.math.minInt(isize), 10, 4);
    try expectState(view, 0, 0);
}
