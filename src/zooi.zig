//! zooi — terminal machinery for small keyboard-driven full-screen programs.
//!
//! The library owns the terminal: raw mode, the alternate screen, resize
//! notification, key decoding, and a buffered frame. It owns nothing else. The
//! application owns its model, its update function, its key bindings, and its
//! rendering.
//!
//! See README.md for the public API.

const std = @import("std");

pub const Key = @import("input.zig").Key;

test {
    std.testing.refAllDecls(@This());
}
