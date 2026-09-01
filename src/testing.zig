//! Read-only views of successfully presented frames for render tests.

const event = @import("event.zig");
const screen = @import("screen.zig");

/// Logical cell values from a successfully presented frame.
///
/// `text` borrows storage owned by `Screen`. Consume it before the next call
/// to `present()` and never retain it across `Screen.deinit()`.
pub const CellView = struct {
    text: []const u8,
    style: screen.Style,
    columns: u2,
    continuation: bool,
};

/// Dimensions of the last successfully presented frame, or null if no valid
/// frame has been committed.
pub fn presentedSize(value: *const screen.Screen) ?event.Size {
    if (!value.front_valid) return null;
    return value.front_size;
}

/// Inspect one cell in the last successfully presented frame.
///
/// The returned text borrows `Screen` storage and is valid only until the next
/// `present()` or until `Screen.deinit()`.
pub fn inspectCell(
    value: *const screen.Screen,
    row: u16,
    col: u16,
) ?CellView {
    const size = presentedSize(value) orelse return null;
    if (row >= size.rows or col >= size.cols) return null;

    const index = @as(usize, row) * @as(usize, size.cols) + @as(usize, col);
    const cell = value.front.items[index];
    const text: []const u8 = if (cell.text_len == 0)
        ""
    else
        value.front_text.items[cell.text_off..][0..cell.text_len];
    return .{
        .text = text,
        .style = cell.style,
        .columns = cell.columns,
        .continuation = cell.continuation,
    };
}
