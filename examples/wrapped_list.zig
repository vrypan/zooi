//! A small variable-height list using zooi's wrapping and row-index APIs.
const std = @import("std");
const zooi = @import("zooi");

/// Produce an ASCII paragraph with an exact terminal-column length. Keeping
/// these samples generated makes their intended size obvious without making
/// the example source mostly repeated prose.
fn sampleText(comptime label: []const u8, comptime columns: usize) [columns]u8 {
    @setEvalBranchQuota(10_000);
    if (label.len > columns) @compileError("sample label exceeds its requested width");

    var text: [columns]u8 = undefined;
    var pos: usize = 0;
    for (label) |byte| {
        text[pos] = byte;
        pos += 1;
    }

    const filler = "wrap this text across the viewport. ";
    while (pos < text.len) {
        for (filler) |byte| {
            if (pos == text.len) break;
            text[pos] = byte;
            pos += 1;
        }
    }
    return text;
}

const sample_200 = sampleText("200-column sample: ", 200);
const sample_500 = sampleText("500-column sample: ", 500);
const sample_1000 = sampleText("1000-column sample: ", 1000);

const items = [_][]const u8{
    "A short item.",
    "Accented cafe\u{301}, wide 世界, and an emoji sequence 👩‍💻 stay intact at a wrap boundary.",
    "A deliberately long unbroken token: supercalifragilisticexpialidocious.",
    "First logical line.\n\nA blank line is a visual row too.",
    sample_200[0..],
    sample_500[0..],
    sample_1000[0..],
};

const Cache = struct {
    // At one column, the 1,000-column sample alone needs 1,000 fragments.
    fragments: [4096]zooi.wrap.Fragment = undefined,
    heights: [items.len]usize = undefined,
    offsets: [items.len + 1]usize = undefined,
    starts: [items.len]usize = undefined,
    count: usize = 0,
    index: zooi.RowIndex = undefined,

    fn reflow(self: *Cache, columns: usize) !void {
        self.count = 0;
        for (items, 0..) |item, i| {
            self.starts[i] = self.count;
            var it = try zooi.wrap.iterator(item, columns, .word);
            while (it.next()) |fragment| {
                if (self.count == self.fragments.len) return error.OutOfMemory;
                self.fragments[self.count] = fragment;
                self.count += 1;
            }
            self.heights[i] = self.count - self.starts[i];
        }
        self.index = try zooi.RowIndex.build(&self.heights, &self.offsets);
    }
};

fn render(screen: *zooi.Screen, cache: *const Cache, view: zooi.VariableViewport) void {
    screen.begin();
    const style: zooi.Style = .{ .reverse = true };
    var visible = view.visibleItems(cache.index, screen.size.rows);
    while (visible.next()) |entry| {
        const selected = entry.item == view.cursor;
        var row = entry.screen_row;
        while (row < entry.screen_row + entry.row_count) : (row += 1) {
            const fragment = cache.fragments[cache.starts[entry.item] + entry.first_row + row - entry.screen_row];
            screen.move(@intCast(row), 0);
            if (selected) screen.fillToEndOfLine(style);
            if (fragment.kind == .replacement) {
                screen.writeStyled("?", if (selected) style else .{});
            } else {
                screen.writeStyled(items[entry.item][fragment.start..fragment.end], if (selected) style else .{});
            }
        }
    }
    screen.present() catch {};
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug.deinit();
    var ui = zooi.Ui.init(debug.allocator(), .{}) catch return;
    defer ui.deinit();

    var cache: Cache = .{};
    const columns = @as(usize, @max(ui.size().cols, 1));
    try cache.reflow(columns);
    var view: zooi.VariableViewport = .{};
    view.normalize(cache.index, ui.size().rows);
    render(ui.screen(), &cache, view);

    while (try ui.nextEvent()) |event| switch (event) {
        .resize => |size| {
            if (size.cols == 0) continue;
            try cache.reflow(size.cols);
            view.normalize(cache.index, size.rows);
            render(ui.screen(), &cache, view);
        },
        .key => |key| {
            switch (key) {
                .up => view.moveItems(-1, cache.index, ui.size().rows),
                .down => view.moveItems(1, cache.index, ui.size().rows),
                .page_up => view.page(.up, cache.index, ui.size().rows),
                .page_down => view.page(.down, cache.index, ui.size().rows),
                .home => view.setCursor(0, cache.index, ui.size().rows),
                .end => view.setCursor(items.len - 1, cache.index, ui.size().rows),
                .ctrl_c => return,
                .character => |cp| if (cp == 'q') return,
                else => {},
            }
            render(ui.screen(), &cache, view);
        },
    };
}
