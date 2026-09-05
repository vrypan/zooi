const std = @import("std");
const example = @import("wrapped_list.zig");

test "wrapped list example is importable" {
    try std.testing.expect(@TypeOf(example) == type);
}
