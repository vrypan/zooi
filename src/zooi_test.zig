//! Test root for the module surface. Each concern gains its own `*_test.zig`
//! beside this one and its own entry in `build.zig`'s `roots`.

const std = @import("std");
const zooi = @import("zooi");

test "the module builds and is importable" {
    try std.testing.expect(@TypeOf(zooi) == type);
}
