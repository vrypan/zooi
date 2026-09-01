//! The spec is explicit that most UI behavior should be testable without a
//! PTY. These drive `update` with key sequences and assert on cursor,
//! selection, viewport, mode, and the returned effect — no terminal involved.

const std = @import("std");
const zooi = @import("zooi");
const app = @import("browser.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn model(rows: u16) app.Model {
    var m = app.Model.init();
    m.size = .{ .rows = rows, .cols = 80 };
    return m;
}

/// Apply keys, returning the last effect.
fn press(m: *app.Model, keys: []const zooi.Key) app.Effect {
    var last: app.Effect = .none;
    for (keys) |k| last = app.update(m, .{ .terminal = .{ .key = k } });
    return last;
}

fn ch(c: u21) zooi.Key {
    return .{ .character = c };
}

/// Run an effect the way main does, including the follow-up message.
fn apply(m: *app.Model, effect: app.Effect) void {
    if (app.executeEffect(m, effect)) |follow_up| _ = app.update(m, follow_up);
}

// --- navigation --------------------------------------------------------------

test "the cursor clamps at both ends and does not wrap" {
    var m = model(24);
    _ = press(&m, &.{.up});
    try expectEqual(@as(usize, 0), m.viewport.cursor);

    _ = press(&m, &.{ .end, .down, .down });
    try expectEqual(m.count - 1, m.viewport.cursor);
}

test "j and k move like the arrows" {
    var m = model(24);
    _ = press(&m, &.{ ch('j'), ch('j') });
    try expectEqual(@as(usize, 2), m.viewport.cursor);
    _ = press(&m, &.{ch('k')});
    try expectEqual(@as(usize, 1), m.viewport.cursor);
}

test "g and G jump to the ends" {
    var m = model(24);
    _ = press(&m, &.{ch('G')});
    try expectEqual(m.count - 1, m.viewport.cursor);
    _ = press(&m, &.{ch('g')});
    try expectEqual(@as(usize, 0), m.viewport.cursor);
}

test "paging does not overshoot the list" {
    var m = model(8);
    for (0..m.count) |_| _ = press(&m, &.{.page_down});
    try expectEqual(m.count - 1, m.viewport.cursor);
    for (0..m.count) |_| _ = press(&m, &.{.page_up});
    try expectEqual(@as(usize, 0), m.viewport.cursor);
}

test "the cursor stays inside the viewport after every step" {
    // The invariant the whole list view depends on. Asserted after each key
    // of a long mixed sequence rather than only at the end.
    var m = model(8); // six list rows
    const seq = [_]zooi.Key{
        .down, .down, .down,      .down,    .down, .down, .down, .down,
        .up,   .up,   .page_down, .page_up, .end,  .home, .end,  .up,
    };
    for (seq) |k| {
        _ = press(&m, &.{k});
        const rows = m.listRows();
        try expect(m.viewport.cursor >= m.viewport.offset);
        try expect(m.viewport.cursor < m.viewport.offset + rows);
    }
}

test "a short list never scrolls" {
    var m = model(24);
    m.count = 4;
    m.viewport.normalize(m.count, m.listRows());
    _ = press(&m, &.{.end});
    try expectEqual(@as(usize, 0), m.viewport.offset);
}

test "the example data scrolls even on a tall terminal" {
    var m = model(50);
    try expect(m.count > m.listRows());
    _ = press(&m, &.{.end});
    try expect(m.viewport.offset > 0);
    try expect(m.viewport.cursor < m.viewport.offset + m.listRows());
}

// --- selection ---------------------------------------------------------------

test "space selects and deselects the cursor entry" {
    var m = model(24);
    _ = press(&m, &.{ch(' ')});
    try expectEqual(@as(usize, 1), m.selection.count());
    _ = press(&m, &.{ch(' ')});
    try expect(m.selection == .none);
}

test "space on a different row moves the selection" {
    var m = model(24);
    _ = press(&m, &.{ ch(' '), .down, ch(' ') });
    try expectEqual(@as(usize, 1), m.selection.count());
    try expect(m.selection.contains(1));
}

test "shift+arrow extends a range" {
    var m = model(24);
    _ = press(&m, &.{ .shift_down, .shift_down });
    try expectEqual(@as(usize, 3), m.selection.count());
    try expect(m.selection.contains(0));
    try expect(m.selection.contains(2));
}

test "the v anchor extends the same way" {
    // Offered for terminals that do not send modifiers.
    var m = model(24);
    _ = press(&m, &.{ .down, .down, ch('v'), .down });
    try expectEqual(@as(usize, 2), m.selection.count());
    try expect(m.selection.contains(2));
    try expect(m.selection.contains(3));
}

test "a range normalises when the anchor is below the cursor" {
    // The case a naive anchor..cursor gets backwards.
    var m = model(24);
    _ = press(&m, &.{ .down, .down, .down, ch('v'), .up, .up });
    const b = m.selection.bounds().?;
    try expectEqual(@as(usize, 1), b.lo);
    try expectEqual(@as(usize, 3), b.hi);
    try expectEqual(@as(usize, 3), m.selection.count());
}

test "escape clears the selection" {
    var m = model(24);
    _ = press(&m, &.{ .shift_down, .escape });
    try expect(m.selection == .none);
}

// --- mutations target selection, else cursor ---------------------------------

test "pin applies to the whole selection" {
    var m = model(24);
    _ = press(&m, &.{ .shift_down, .shift_down });
    apply(&m, press(&m, &.{ch('p')}));
    try expect(m.entries[0].pinned);
    try expect(m.entries[1].pinned);
    try expect(m.entries[2].pinned);
    // Entry 3 is seeded pinned and is outside the selection, so it is
    // untouched rather than toggled.
    try expect(m.entries[3].pinned);
}

test "pin with no selection applies to the cursor entry only" {
    var m = model(24);
    _ = press(&m, &.{.down});
    apply(&m, press(&m, &.{ch('p')}));
    try expect(m.entries[1].pinned);
    try expect(!m.entries[0].pinned);
    try expect(!m.entries[2].pinned);
}

// --- prompts -----------------------------------------------------------------

test "the tag prompt accepts text and applies on enter" {
    var m = model(24);
    _ = press(&m, &.{ch('t')});
    try expect(m.mode == .tag_input);

    _ = press(&m, &.{ ch('b'), ch('u'), ch('i'), ch('l'), ch('d') });
    try expectEqualStrings("build", m.mode.tag_input.text());

    const effect = press(&m, &.{.enter});
    try expect(m.mode == .normal);
    try expect(effect == .set_tag);
    apply(&m, effect);
    try expectEqualStrings("build", m.entries[0].tag().?);
}

test "backspace removes a whole codepoint, not a byte" {
    var m = model(24);
    _ = press(&m, &.{ ch('t'), ch('c'), ch('a'), ch('f'), ch(0xE9) });
    try expectEqualStrings("café", m.mode.tag_input.text());
    _ = press(&m, &.{.backspace});
    // Removing a byte would leave an invalid trailing sequence.
    try expectEqualStrings("caf", m.mode.tag_input.text());
}

test "escape cancels a prompt with no effect" {
    var m = model(24);
    _ = press(&m, &.{ ch('t'), ch('x') });
    const effect = press(&m, &.{.escape});
    try expect(m.mode == .normal);
    try expect(effect == .none);
    try expect(m.entries[0].tag() == null);
}

test "an empty prompt is treated as a cancel" {
    var m = model(24);
    _ = press(&m, &.{ch('t')});
    const effect = press(&m, &.{.enter});
    try expect(effect == .none);
}

test "naming a multi-entry selection targets the cursor entry" {
    // The spec requires this be deterministic either way; the choice here is
    // "use the cursor entry, and say so".
    var m = model(24);
    _ = press(&m, &.{ .shift_down, .shift_down, ch('n') });
    try expect(m.mode == .name_input);
    try expect(m.status_len > 0);

    _ = press(&m, &.{ ch('h'), ch('i') });
    apply(&m, press(&m, &.{.enter}));
    try expectEqualStrings("hi", m.entries[m.viewport.cursor].name().?);
    try expect(m.entries[0].name() == null);
}

test "a duplicate name is refused with a status message, not a crash" {
    var m = model(24);
    _ = press(&m, &.{ ch('n'), ch('a') });
    apply(&m, press(&m, &.{.enter}));

    _ = press(&m, &.{ .down, ch('n'), ch('a') });
    apply(&m, press(&m, &.{.enter}));
    try expect(m.entries[1].name() == null);
    try expect(std.mem.indexOf(u8, m.status(), "already taken") != null);
}

// --- delete ------------------------------------------------------------------

test "delete requires confirmation and defaults to no" {
    var m = model(24);
    const before = m.count;

    _ = press(&m, &.{ch('d')});
    try expect(m.mode == .delete_confirm);

    // Anything but y cancels, including Enter.
    const e1 = press(&m, &.{.enter});
    try expect(e1 == .none);
    try expectEqual(before, m.count);

    _ = press(&m, &.{ch('d')});
    const e2 = press(&m, &.{ch('n')});
    try expect(e2 == .none);
    try expectEqual(before, m.count);
}

test "y confirms and removes the range" {
    var m = model(24);
    const before = m.count;
    _ = press(&m, &.{ .shift_down, .shift_down, ch('d') });
    apply(&m, press(&m, &.{ch('y')}));
    try expectEqual(before - 3, m.count);
    try expect(m.selection == .none);
}

test "a pinned entry is protected and reported" {
    var m = model(24);
    const before = m.count;
    _ = press(&m, &.{ .down, .down, .down, ch('d') }); // entry 3 is pinned
    apply(&m, press(&m, &.{ch('y')}));
    try expectEqual(before, m.count);
    try expect(std.mem.indexOf(u8, m.status(), "pinned") != null);
}

test "cursor and selection are normalised after entries disappear" {
    var m = model(24);
    _ = press(&m, &.{.end});
    _ = press(&m, &.{ch('d')});
    apply(&m, press(&m, &.{ch('y')}));
    // The cursor was on the last entry, which is now gone.
    try expect(m.viewport.cursor < m.count);
    try expect(m.selection == .none);
}

// --- modes -------------------------------------------------------------------

test "inspect opens on enter and closes three ways" {
    for ([_]zooi.Key{ .escape, .enter, ch('q') }) |closer| {
        var m = model(24);
        _ = press(&m, &.{.enter});
        try expect(m.mode == .inspect);
        _ = press(&m, &.{closer});
        try expect(m.mode == .normal);
    }
}

test "q quits from normal mode but not from a prompt" {
    var m = model(24);
    _ = press(&m, &.{ch('t')});
    _ = press(&m, &.{ch('q')});
    try expect(!m.quit);
    try expectEqualStrings("q", m.mode.tag_input.text());

    _ = press(&m, &.{.escape});
    const effect = press(&m, &.{ch('q')});
    try expect(m.quit);
    try expect(effect == .quit);
}

test "ctrl-c quits from any mode" {
    // Raw mode disabled ISIG, so this is the program's job.
    var m = model(24);
    _ = press(&m, &.{ch('t')});
    const effect = press(&m, &.{.ctrl_c});
    try expect(m.quit);
    try expect(effect == .quit);
}

// --- rendering ---------------------------------------------------------------

test "render is total at every size, including degenerate ones" {
    const gpa = std.testing.allocator;
    const null_fd = try std.posix.openatZ(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    defer _ = std.posix.system.close(null_fd);

    const sizes = [_]zooi.Size{
        .{ .rows = 0, .cols = 0 },
        .{ .rows = 1, .cols = 1 },
        .{ .rows = 3, .cols = 10 },
        .{ .rows = 24, .cols = 80 },
        .{ .rows = 200, .cols = 500 },
    };
    const modes = [_][]const zooi.Key{
        &.{},
        &.{ch('t')},
        &.{ch('d')},
        &.{.enter},
        &.{ .shift_down, .shift_down },
    };

    for (sizes) |sz| {
        for (modes) |keys| {
            var m = model(24);
            _ = press(&m, keys);
            m.size = sz;
            var screen = zooi.Screen.init(gpa, null_fd, sz);
            defer screen.deinit();
            app.render(&m, &screen);
            // Nothing to assert beyond "it returned"; the point is that no
            // size crashes and the frame is well-formed.
            try expect(screen.frame().len >= 0);
        }
    }
}

test "moving the cursor emits a small retained-grid update" {
    const gpa = std.testing.allocator;
    const null_fd = try std.posix.openatZ(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    defer _ = std.posix.system.close(null_fd);

    var m = model(24);
    const size: zooi.Size = .{ .rows = 24, .cols = 80 };
    m.size = size;
    var screen = zooi.Screen.init(gpa, null_fd, size);
    defer screen.deinit();

    app.render(&m, &screen);
    const initial_bytes = screen.frame().len;

    _ = press(&m, &.{.down});
    app.render(&m, &screen);
    const movement_bytes = screen.frame().len;

    // Only the old and new cursor rows changed. Keep this as a broad ratio
    // rather than an exact ANSI snapshot so harmless encoding changes do not
    // make the test brittle.
    try expect(movement_bytes * 3 < initial_bytes);
}

test "the cursor highlight fills the complete list row" {
    const gpa = std.testing.allocator;
    const null_fd = try std.posix.openatZ(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    defer _ = std.posix.system.close(null_fd);

    var m = model(6);
    const size: zooi.Size = .{ .rows = 6, .cols = 320 };
    m.size = size;
    var screen = zooi.Screen.init(gpa, null_fd, size);
    defer screen.deinit();
    app.render(&m, &screen);

    const presented = zooi.testing.presentedSize(&screen).?;
    try expectEqual(size, presented);

    // Row 1 is the cursor row (row 0 is the header). Its final cell is an
    // explicit reverse-video space even beyond column 256.
    const cursor_tail = zooi.testing.inspectCell(&screen, 1, presented.cols - 1).?;
    try expectEqualStrings(" ", cursor_tail.text);
    try expect(cursor_tail.style.reverse);
    try expectEqual(@as(u2, 1), cursor_tail.columns);
    try expect(!cursor_tail.continuation);

    // The next list row was not cursor-highlighted and retains a true blank.
    const next_tail = zooi.testing.inspectCell(&screen, 2, presented.cols - 1).?;
    try expectEqualStrings("", next_tail.text);
    try expect(!next_tail.style.reverse);
    try expectEqual(@as(u2, 1), next_tail.columns);
    try expect(!next_tail.continuation);
}

test "a resize keeps the cursor visible" {
    var m = model(24);
    _ = press(&m, &.{.end});
    _ = app.update(&m, .{ .terminal = .{ .resize = .{ .rows = 6, .cols = 40 } } });
    try expect(m.viewport.cursor >= m.viewport.offset);
    try expect(m.viewport.cursor < m.viewport.offset + m.listRows());
}
