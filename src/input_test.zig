const std = @import("std");
const input = @import("input.zig");

const Key = input.Key;
const Parser = input.Parser;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Feed one slice and collect every key it yields.
fn keys(bytes: []const u8, out: []Key) []Key {
    var p: Parser = .{};
    _ = p.feed(bytes);
    var n: usize = 0;
    while (p.next()) |k| : (n += 1) out[n] = k;
    return out[0..n];
}

fn one(bytes: []const u8) ?Key {
    var buf: [8]Key = undefined;
    const got = keys(bytes, &buf);
    return if (got.len == 1) got[0] else null;
}

test "single-byte keys" {
    try expectEqual(Key.ctrl_c, one("\x03").?);
    try expectEqual(Key.enter, one("\r").?);
    try expectEqual(Key.enter, one("\n").?);
    try expectEqual(Key.backspace, one("\x7f").?);
    try expectEqual(Key.backspace, one("\x08").?);
}

test "printable characters decode as codepoints" {
    try expectEqual(@as(u21, 'a'), one("a").?.character);
    try expectEqual(@as(u21, 0xE9), one("é").?.character);
    try expectEqual(@as(u21, 0x4E16), one("世").?.character);
    try expectEqual(@as(u21, 0x1F642), one("🙂").?.character);
}

test "unbound control bytes are dropped, not surfaced" {
    var buf: [8]Key = undefined;
    // Tab, and a few other C0 bytes the spec does not bind.
    try expectEqual(@as(usize, 0), keys("\x09", &buf).len);
    try expectEqual(@as(usize, 0), keys("\x01\x02\x04", &buf).len);
}

test "CSI sequences" {
    try expectEqual(Key.up, one("\x1b[A").?);
    try expectEqual(Key.down, one("\x1b[B").?);
    try expectEqual(Key.right, one("\x1b[C").?);
    try expectEqual(Key.left, one("\x1b[D").?);
    try expectEqual(Key.home, one("\x1b[H").?);
    try expectEqual(Key.end, one("\x1b[F").?);
    try expectEqual(Key.page_up, one("\x1b[5~").?);
    try expectEqual(Key.page_down, one("\x1b[6~").?);
    try expectEqual(Key.delete, one("\x1b[3~").?);
    try expectEqual(Key.shift_up, one("\x1b[1;2A").?);
    try expectEqual(Key.shift_down, one("\x1b[1;2B").?);
}

test "SS3 sequences, sent under cursor-key application mode" {
    try expectEqual(Key.up, one("\x1bOA").?);
    try expectEqual(Key.down, one("\x1bOB").?);
    try expectEqual(Key.right, one("\x1bOC").?);
    try expectEqual(Key.left, one("\x1bOD").?);
    try expectEqual(Key.home, one("\x1bOH").?);
    try expectEqual(Key.end, one("\x1bOF").?);
}

test "every spelling of Home and End" {
    // xterm, the Linux console, and rxvt each send a different one.
    for ([_][]const u8{ "\x1b[H", "\x1bOH", "\x1b[1~", "\x1b[7~" }) |s|
        try expectEqual(Key.home, one(s).?);
    for ([_][]const u8{ "\x1b[F", "\x1bOF", "\x1b[4~", "\x1b[8~" }) |s|
        try expectEqual(Key.end, one(s).?);
}

test "a sequence split across reads resolves when the rest arrives" {
    // The property spec 11.1 exists for.
    var p: Parser = .{};

    _ = p.feed("\x1b");
    try expect(p.next() == null);
    try expect(p.awaitingEscape());

    _ = p.feed("[");
    try expect(p.next() == null);
    try expect(p.awaitingEscape());

    _ = p.feed("A");
    try expectEqual(Key.up, p.next().?);
    try expect(!p.awaitingEscape());
}

test "a UTF-8 character split across reads is not an escape wait" {
    // Incomplete, but waiting on more bytes rather than on a timeout: the
    // loop must keep blocking, not arm the escape timer.
    var p: Parser = .{};
    _ = p.feed("\xe4\xb8");
    try expect(p.next() == null);
    try expect(!p.awaitingEscape());

    _ = p.feed("\x96");
    try expectEqual(@as(u21, 0x4E16), p.next().?.character);
}

test "a UTF-8 character split the other way" {
    var p: Parser = .{};
    _ = p.feed("\xe4");
    try expect(p.next() == null);
    _ = p.feed("\xb8\x96");
    try expectEqual(@as(u21, 0x4E16), p.next().?.character);
}

test "several keys in one read" {
    var buf: [8]Key = undefined;
    const got = keys("abc", &buf);
    try expectEqual(@as(usize, 3), got.len);
    try expectEqual(@as(u21, 'a'), got[0].character);
    try expectEqual(@as(u21, 'c'), got[2].character);
}

test "several escape sequences in one read" {
    var buf: [8]Key = undefined;
    const got = keys("\x1b[A\x1b[B", &buf);
    try expectEqual(@as(usize, 2), got.len);
    try expectEqual(Key.up, got[0]);
    try expectEqual(Key.down, got[1]);
}

test "a lone ESC becomes Escape only on timeout" {
    var p: Parser = .{};
    _ = p.feed("\x1b");
    try expect(p.next() == null);
    try expect(p.awaitingEscape());
    try expectEqual(Key.escape, p.timeout().?);
    try expect(!p.awaitingEscape());
    try expect(p.next() == null);
}

test "timeout with nothing pending yields nothing" {
    var p: Parser = .{};
    try expect(p.timeout() == null);
    _ = p.feed("a");
    try expect(p.timeout() == null);
}

test "ESC then an ordinary byte is Escape followed by that byte" {
    // Alt+A and "Escape, then A" are indistinguishable at this layer. v1 has
    // no Alt bindings, so this resolves without waiting for the timeout.
    var buf: [8]Key = undefined;
    const got = keys("\x1ba", &buf);
    try expectEqual(@as(usize, 2), got.len);
    try expectEqual(Key.escape, got[0]);
    try expectEqual(@as(u21, 'a'), got[1].character);
}

test "unknown but well-formed sequences are swallowed whole" {
    var buf: [8]Key = undefined;
    // Bracketed paste. Without this, pasting types `200~` into a prompt.
    try expectEqual(@as(usize, 0), keys("\x1b[200~", &buf).len);
    try expectEqual(@as(usize, 0), keys("\x1b[?25l", &buf).len);
    // And the buffer is left clean for the next key.
    var p: Parser = .{};
    _ = p.feed("\x1b[200~a");
    try expectEqual(@as(u21, 'a'), p.next().?.character);
}

test "an unknown SS3 final is swallowed whole" {
    var buf: [8]Key = undefined;
    try expectEqual(@as(usize, 0), keys("\x1bOZ", &buf).len);
}

test "invalid UTF-8 is dropped and the parser recovers" {
    var p: Parser = .{};
    _ = p.feed("\xffa");
    try expectEqual(@as(u21, 'a'), p.next().?.character);

    // A continuation byte with no lead is equally bogus.
    var q: Parser = .{};
    _ = q.feed("\x80b");
    try expectEqual(@as(u21, 'b'), q.next().?.character);
}

test "overflow resets the parser and it keeps working" {
    var p: Parser = .{};
    var big: [40]u8 = undefined;
    @memset(&big, '1');
    big[0] = 0x1b;
    big[1] = '[';
    try expect(!p.feed(&big));
    try expect(p.next() == null);
    try expect(!p.awaitingEscape());

    try expect(p.feed("\x1b[A"));
    try expectEqual(Key.up, p.next().?);
}

test "awaitingEscape looks past leading dropped bytes" {
    var p: Parser = .{};
    _ = p.feed("\x01\x1b");
    try expect(p.next() == null);
    try expect(p.awaitingEscape());
}

test "fuzz: never panics, never loops, never invents a key from nothing" {
    // Exhaustive over an alphabet chosen to hit every branch, to length 4.
    const alphabet = [_]u8{ 0x1b, '[', 'O', 'A', '1', ';', '2', '~', 'a', 0xff, 0x03 };
    var seq: [4]u8 = undefined;

    for (alphabet) |a| {
        seq[0] = a;
        for (alphabet) |b| {
            seq[1] = b;
            for (alphabet) |c| {
                seq[2] = c;
                for (alphabet) |d| {
                    seq[3] = d;

                    var p: Parser = .{};
                    try expect(p.feed(&seq));
                    var guard: usize = 0;
                    while (p.next()) |_| {
                        guard += 1;
                        // Four bytes cannot yield more than four keys.
                        try expect(guard <= 4);
                    }
                    // Whatever is left must be an incomplete escape or an
                    // incomplete character; either way, draining is idempotent.
                    try expect(p.next() == null);
                }
            }
        }
    }

    // An empty parser reports nothing under every query.
    var e: Parser = .{};
    try expect(e.next() == null);
    try expect(!e.awaitingEscape());
    try expect(e.timeout() == null);
}
