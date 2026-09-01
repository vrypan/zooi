//! zooi — terminal machinery for small keyboard-driven full-screen programs.
//!
//! The library owns the terminal: raw mode, the alternate screen, resize
//! notification, key decoding, and a buffered frame. It owns nothing else. The
//! application owns its model, its update function, its key bindings, and its
//! rendering.
//!
//! See README.md for the public API.

const std = @import("std");

pub const Ui = @import("event.zig").Ui;
pub const Event = @import("event.zig").Event;
pub const Key = @import("input.zig").Key;
pub const Size = @import("event.zig").Size;
pub const Screen = @import("screen.zig").Screen;
pub const Style = @import("screen.zig").Style;
pub const Color = @import("screen.zig").Color;
pub const Viewport = @import("viewport.zig").Viewport;
pub const restore = @import("terminal.zig").restore;

/// Columns a UTF-8 string occupies in a terminal, which is not its byte
/// length. Exported because laying out columns is the application's job and
/// it cannot be done by measuring bytes: `é` is two bytes and one column,
/// `世` three bytes and two, a combining mark two bytes and none.
///
/// Per-codepoint. Grapheme clusters and ZWJ emoji sequences are out of scope.
pub const displayWidth = @import("width.zig").strWidth;

test {
    std.testing.refAllDecls(@This());
}
