const std = @import("std");
const zooi = @import("zooi");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const gpa = std.testing.allocator;

var null_fd: std.posix.fd_t = -1;

fn nullFd() std.posix.fd_t {
    if (null_fd < 0)
        null_fd = std.posix.openatZ(
            std.posix.AT.FDCWD,
            "/dev/null",
            .{ .ACCMODE = .WRONLY },
            0,
        ) catch unreachable;
    return null_fd;
}

fn testScreen(rows: u16, cols: u16) zooi.Screen {
    return zooi.Screen.init(gpa, nullFd(), .{ .rows = rows, .cols = cols });
}

test "inspection is absent before the first successful presentation" {
    var screen = testScreen(2, 4);
    defer screen.deinit();
    try expect(zooi.testing.presentedSize(&screen) == null);
    try expect(zooi.testing.inspectCell(&screen, 0, 0) == null);
}

test "a successful zero-sized frame is inspectable but has no cells" {
    var screen = testScreen(0, 0);
    defer screen.deinit();
    screen.begin();
    try screen.present();
    try expectEqual(zooi.Size{ .rows = 0, .cols = 0 }, zooi.testing.presentedSize(&screen).?);
    try expect(zooi.testing.inspectCell(&screen, 0, 0) == null);
}

test "inspection rejects coordinates at or beyond presented bounds" {
    var screen = testScreen(2, 3);
    defer screen.deinit();
    screen.begin();
    try screen.present();
    try expect(zooi.testing.inspectCell(&screen, 0, 0) != null);
    try expect(zooi.testing.inspectCell(&screen, 2, 0) == null);
    try expect(zooi.testing.inspectCell(&screen, 0, 3) == null);
    try expect(zooi.testing.inspectCell(&screen, std.math.maxInt(u16), 0) == null);
}

test "ASCII, default blanks, and explicit styled spaces stay distinct" {
    const style: zooi.Style = .{ .reverse = true };
    var screen = testScreen(1, 4);
    defer screen.deinit();
    screen.begin();
    screen.writeStyled("A ", style);
    try screen.present();

    const ascii = zooi.testing.inspectCell(&screen, 0, 0).?;
    try expectEqualStrings("A", ascii.text);
    try expect(std.meta.eql(style, ascii.style));
    try expectEqual(@as(u2, 1), ascii.columns);
    try expect(!ascii.continuation);

    const explicit = zooi.testing.inspectCell(&screen, 0, 1).?;
    try expectEqualStrings(" ", explicit.text);
    try expect(std.meta.eql(style, explicit.style));
    try expectEqual(@as(u2, 1), explicit.columns);
    try expect(!explicit.continuation);

    const blank = zooi.testing.inspectCell(&screen, 0, 2).?;
    try expectEqualStrings("", blank.text);
    try expect(std.meta.eql(zooi.Style{}, blank.style));
    try expectEqual(@as(u2, 1), blank.columns);
    try expect(!blank.continuation);
}

test "wide glyph heads and continuations expose logical cell values" {
    const style: zooi.Style = .{ .bold = true };
    var screen = testScreen(1, 4);
    defer screen.deinit();
    screen.begin();
    screen.writeStyled("世", style);
    try screen.present();

    const head = zooi.testing.inspectCell(&screen, 0, 0).?;
    try expectEqualStrings("世", head.text);
    try expect(std.meta.eql(style, head.style));
    try expectEqual(@as(u2, 2), head.columns);
    try expect(!head.continuation);

    const continuation = zooi.testing.inspectCell(&screen, 0, 1).?;
    try expectEqualStrings("", continuation.text);
    try expect(std.meta.eql(style, continuation.style));
    try expectEqual(@as(u2, 0), continuation.columns);
    try expect(continuation.continuation);
}

test "combining marks remain attached to their head cell" {
    var screen = testScreen(1, 4);
    defer screen.deinit();
    screen.begin();
    screen.write("e\u{301}");
    try screen.present();
    try expectEqualStrings("e\u{301}", zooi.testing.inspectCell(&screen, 0, 0).?.text);
}

test "building a frame does not change inspection until it is presented" {
    var screen = testScreen(1, 4);
    defer screen.deinit();
    screen.begin();
    screen.write("old");
    try screen.present();

    screen.size = .{ .rows = 2, .cols = 6 };
    screen.begin();
    screen.write("new");
    try expectEqual(zooi.Size{ .rows = 1, .cols = 4 }, zooi.testing.presentedSize(&screen).?);
    try expectEqualStrings("o", zooi.testing.inspectCell(&screen, 0, 0).?.text);
    try screen.present();
    try expectEqual(zooi.Size{ .rows = 2, .cols = 6 }, zooi.testing.presentedSize(&screen).?);
    try expectEqualStrings("n", zooi.testing.inspectCell(&screen, 0, 0).?.text);
}

test "a successful presentation replaces inspected size and contents" {
    var screen = testScreen(1, 4);
    defer screen.deinit();
    screen.begin();
    screen.write("a");
    try screen.present();

    screen.size = .{ .rows = 2, .cols = 6 };
    screen.begin();
    screen.move(1, 5);
    screen.write("z");
    try screen.present();
    try expectEqual(zooi.Size{ .rows = 2, .cols = 6 }, zooi.testing.presentedSize(&screen).?);
    try expectEqualStrings("z", zooi.testing.inspectCell(&screen, 1, 5).?.text);
}

test "a failed presentation invalidates an earlier inspected frame" {
    const fd = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        "/dev/null",
        .{ .ACCMODE = .WRONLY },
        0,
    );
    var screen = zooi.Screen.init(gpa, fd, .{ .rows = 1, .cols = 4 });
    defer screen.deinit();

    screen.begin();
    screen.write("old");
    try screen.present();
    try expect(zooi.testing.presentedSize(&screen) != null);

    _ = std.posix.system.close(fd);
    screen.begin();
    screen.write("new");
    try std.testing.expectError(error.WriteFailed, screen.present());
    try expect(zooi.testing.presentedSize(&screen) == null);
    try expect(zooi.testing.inspectCell(&screen, 0, 0) == null);
}
