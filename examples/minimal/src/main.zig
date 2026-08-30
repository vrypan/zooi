const std = @import("std");
const zooi = @import("zooi");

const items = [_][]const u8{ "alpha", "beta", "gamma", "delta" };

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug.deinit();

    var ui = try zooi.Ui.init(debug.allocator(), .{});
    defer ui.deinit();

    var cursor: usize = 0;
    var running = true;
    try render(&ui, cursor);

    const max_events_per_frame = 64;
    while (running) {
        const first = (try ui.nextEvent()) orelse break;
        var pending: ?zooi.Event = first;
        var handled: usize = 0;
        while (pending) |event| {
            update(&cursor, &running, event);
            handled += 1;
            if (!running or handled == max_events_per_frame) break;
            pending = try ui.pollEvent();
        }
        if (running) try render(&ui, cursor);
    }
}

fn update(cursor: *usize, running: *bool, event: zooi.Event) void {
    switch (event) {
        .key => |key| switch (key) {
            .up => cursor.* = cursor.* -| 1,
            .down => cursor.* = @min(cursor.* + 1, items.len - 1),
            .ctrl_c => running.* = false,
            .character => |c| if (c == 'q') {
                running.* = false;
            },
            else => {},
        },
        .resize => {},
    }
}

fn render(ui: *zooi.Ui, cursor: usize) !void {
    const screen = ui.screen();
    screen.begin();
    for (items, 0..) |item, i| {
        screen.move(@intCast(i), 0);
        if (i == cursor) {
            screen.writeStyled("> ", .{ .bold = true });
            screen.writeStyled(item, .{ .reverse = true });
        } else {
            screen.write("  ");
            screen.write(item);
        }
    }
    try screen.present();
}
