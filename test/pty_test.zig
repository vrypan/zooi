//! Terminal-specific behaviour, and nothing else.
//!
//! §26 splits the testing work deliberately: raw-mode lifecycle, alternate
//! screen, key decoding, resize, and restoration need a real terminal, and
//! everything else is already covered without one by the unit suites. A test
//! that could have been a unit test does not belong here — it would only be a
//! slower, flakier way to learn the same thing.
//!
//! Restoration is the one that matters most. It is the only requirement whose
//! violation the user experiences as a broken shell rather than a broken
//! program, which they can only fix by typing `reset` blind.
//!
//! Every test drives the installed example browser through `test/pty.zig`, and
//! every wait is for a marker the example emits, never for a duration.

const std = @import("std");
const posix = std.posix;
const pty = @import("pty.zig");
const options = @import("build_options");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const gpa = std.testing.allocator;

/// Generous, because it only bounds failure. A passing test returns as soon as
/// its marker arrives, so raising this costs nothing but bad-day patience.
const timeout_ms = 5000;

const leave_alt = "\x1b[?1049l";
const enter_alt = "\x1b[?1049h";
const restore_tail = leave_alt ++ "\x1b[0m";

fn start(rows: u16, cols: u16) !pty.PtyChild {
    return pty.spawn(gpa, &.{options.browser}, .{ .rows = rows, .cols = cols }) catch |err| switch (err) {
        // No pty to be had: a container without /dev/ptmx is not a failure.
        error.PtyUnavailable => error.SkipZigTest,
        else => err,
    };
}

test "raw mode is entered while running and restored on exit" {
    var child = try start(24, 80);
    defer child.deinit();
    try expect(try child.waitFrames(1, timeout_ms));

    // A pty master and its slave share one line discipline, so this is the
    // state the child put the terminal into.
    const live = try child.termios();
    try expect(!live.lflag.ECHO);
    try expect(!live.lflag.ICANON);
    // ISIG off is why Ctrl-C arrives as a key rather than a signal.
    try expect(!live.lflag.ISIG);
    try expect(live.lflag.ECHO != child.initial.lflag.ECHO);

    try child.send("q");
    try expectEqual(@as(u8, 0), try child.wait(timeout_ms));

    const after = try child.termios();
    try expectEqual(child.initial.lflag.ECHO, after.lflag.ECHO);
    try expectEqual(child.initial.lflag.ICANON, after.lflag.ICANON);
    try expectEqual(child.initial.lflag.ISIG, after.lflag.ISIG);
    try expectEqual(child.initial.oflag.OPOST, after.oflag.OPOST);
}

test "the alternate screen is entered first and left last" {
    var child = try start(24, 80);
    defer child.deinit();
    try expect(try child.waitFrames(1, timeout_ms));

    const first_frame = child.output.items.len;
    try expect(std.mem.indexOf(u8, child.output.items, enter_alt) != null);

    try child.send("q");
    try expectEqual(@as(u8, 0), try child.wait(timeout_ms));

    // Entering has to precede the first frame, or the frame lands on the
    // user's scrollback.
    const alt_at = std.mem.indexOf(u8, child.output.items, enter_alt).?;
    try expect(alt_at < first_frame);

    // Leaving has to be the last thing written. A restore followed by one more
    // stray frame leaves the terminal wrong in exactly the way that is hardest
    // to notice in review.
    try expect(std.mem.endsWith(u8, child.output.items, restore_tail));
}

test "keys decoded from a real terminal move the selection" {
    var child = try start(24, 80);
    defer child.deinit();
    try expect(try child.waitFrames(1, timeout_ms));

    // Separate writes, so each is its own frame. Sent together the example
    // would coalesce them into one, which is correct but makes the frame
    // count depend on kernel buffering.
    try child.send("\x1b[B");
    try expect(try child.waitFrames(2, timeout_ms));
    try child.send("\x1b[B");
    try expect(try child.waitFrames(3, timeout_ms));

    // Only the inspect view says which entry is selected, so ask it.
    const before_inspect = child.output.items.len;
    try child.send("\r");
    try expect(try child.waitOutputFrom(before_inspect, "exit status", timeout_ms));

    const shown = child.output.items[before_inspect..];
    // The third entry, reached by two Downs from the first.
    try expect(std.mem.indexOf(u8, shown, "26") != null);
    try expect(std.mem.indexOf(u8, shown, "zig build") != null);

    // In inspect mode `q` closes the view; quitting takes a second one.
    const before_close = child.output.items.len;
    try child.send("q");
    try expect(try child.waitOutputFrom(before_close, "git status", timeout_ms));
    try child.send("q");
    try expectEqual(@as(u8, 0), try child.wait(timeout_ms));
}

test "a lone ESC resolves as Escape, and ESC [ A does not" {
    var child = try start(24, 80);
    defer child.deinit();
    try expect(try child.waitFrames(1, timeout_ms));

    // Half one: a lone ESC has to become the Escape key once the timeout
    // expires, with nothing following it to say so.
    try child.send("t");
    try expect(try child.waitOutput("tag:", timeout_ms));
    const before_esc = child.output.items.len;
    try child.send("\x1b");
    try expect(try child.waitOutputFrom(before_esc, "cancelled", timeout_ms));

    // Half two: the same leading byte, arriving as a complete sequence, is an
    // arrow key. The prompt must survive it and take the following character
    // literally — "tag: x", never "tag: [Ax".
    try child.send("t");
    const before_arrow = child.output.items.len;
    try child.send("\x1b[A");
    try child.send("x");
    try expect(try child.waitOutputFrom(before_arrow, "tag: x", timeout_ms));
    try expect(!std.mem.containsAtLeast(u8, child.output.items[before_arrow..], 1, "cancelled"));

    try child.send("\x1b");
    try expect(try child.waitOutput("cancelled", timeout_ms));
    try child.send("q");
    try expectEqual(@as(u8, 0), try child.wait(timeout_ms));
}

test "a resize reaches the child, and a burst of them coalesces" {
    var child = try start(24, 80);
    defer child.deinit();
    try expect(try child.waitFrames(1, timeout_ms));
    try expect(try child.waitOutput("24x80", timeout_ms));

    // TIOCSWINSZ on the master; the kernel raises SIGWINCH on the pty's
    // foreground process group by itself. Nothing signals the child directly,
    // or this would pass with the controlling terminal set up wrongly.
    try child.resize(30, 100);
    try expect(try child.waitOutput("30x100", timeout_ms));

    // Now a burst, as a window drag produces. The last size must win, and the
    // child must not have painted one frame per notification.
    const before_burst = child.framesPainted();
    var rows: u16 = 31;
    while (rows <= 36) : (rows += 1) try child.resize(rows, 100);
    try expect(try child.waitOutput("36x100", timeout_ms));
    const painted = child.framesPainted() - before_burst;
    try expect(painted >= 1);
    try expect(painted < 6);

    try child.send("q");
    try expectEqual(@as(u8, 0), try child.wait(timeout_ms));
}

test "the terminal is restored after SIGTERM and after a panic" {
    {
        var child = try start(24, 80);
        defer child.deinit();
        try expect(try child.waitFrames(1, timeout_ms));

        child.signal(posix.SIG.TERM);
        // The example's handler calls restore() and exits 130, which is the
        // pattern the README documents for consumers.
        try expectEqual(@as(u8, 130), try child.wait(timeout_ms));
        try expect(std.mem.endsWith(u8, child.output.items, restore_tail));
    }
    {
        var child = try start(24, 80);
        defer child.deinit();
        try expect(try child.waitFrames(1, timeout_ms));

        // A hidden key, reachable only with markers on, makes the example die
        // the way a real bug would.
        try child.send("!");
        const code = try child.wait(timeout_ms);
        try expect(code != 0);
        // The panic handler restores before the default handler prints, so the
        // trace lands on a terminal that works.
        try expect(std.mem.indexOf(u8, child.output.items, leave_alt) != null);
        try expect(std.mem.indexOf(u8, child.marks.items, "panic") != null);
    }
}
