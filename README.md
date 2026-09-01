# zooi

zooi is a small Zig library for keyboard-driven, full-screen terminal programs.
It handles raw mode, the alternate screen, resize events, key decoding, and
retained rendering. The application handles state, key bindings, and layout.

```
┌─ journal pqhx ────────────────────────────────────────────────────┐
│                                                                   │
│   24   0    git status                                            │
│   25   0    zig build test                                        │
│ > 26   1    zig build                                             │
│ * 27   0    git diff                                              │
│                                                                   │
├───────────────────────────────────────────────────────────────────┤
│ ↑↓ move  space select  p pin  t tag  n name  d delete  q quit     │
└───────────────────────────────────────────────────────────────────┘
```

## When to use zooi

zooi provides an event loop, a screen buffer, and styled text.

Use zooi for small programs such as list browsers, pickers, log viewers, and
dashboards. It works best for a single screen with keyboard input and custom
layout code.

Use [libvaxis](https://github.com/rockorager/libvaxis) if you need widgets, a
layout engine, mouse input, terminal graphics, capability negotiation, or a
component library. See [Non-goals](#non-goals).

## Requirements

- Zig **0.16.0**
- No third-party dependencies
- No libc on Linux. Calls use `std.posix` or `std.os.linux` when Zig has no
  POSIX wrapper. macOS uses `libSystem`.

zooi does not call `linkLibC()`. If the application links libc, zooi uses it.

## Install

Add the dependency:

```sh
zig fetch --save git+https://github.com/vrypan/zooi.git#v0.1.3
```

Add the module in `build.zig`:

```zig
const zooi = b.dependency("zooi", .{});
exe.root_module.addImport("zooi", zooi.module("zooi"));
```

To vendor zooi, copy `src/` and use `src/zooi.zig` as the module root. See
[`examples/minimal`](examples/minimal) for a complete consumer project with its
own `build.zig`, `build.zig.zon`, and `src/main.zig`.

## Try it

Run the example browser:

```sh
zig build run
```

Use `j`/`k` or the arrow keys to move. `space` selects, `v` starts a range,
`p` pins, `t` tags, `n` names, `d` deletes, `Enter` inspects, and `q` quits.
The source is `examples/browser.zig`.

## Quick start

This program draws a list, moves a cursor, and quits on `q`:

```zig
const std = @import("std");
const zooi = @import("zooi");

const items = [_][]const u8{ "alpha", "beta", "gamma", "delta" };

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug.deinit();
    const gpa = debug.allocator();

    var ui = try zooi.Ui.init(gpa, .{});
    defer ui.deinit();

    var cursor: usize = 0;
    var running = true;
    try render(&ui, cursor);

    // Apply a short burst of queued input, then render once. The limit keeps a
    // continuous producer from starving the display.
    const max_events_per_frame = 64;
    while (running) {
        const first = (try ui.nextEvent()) orelse break;
        var pending: ?zooi.Event = first;
        var handled: usize = 0;
        while (pending) |event| {
            switch (event) {
                .key => |key| switch (key) {
                    .up => cursor -|= 1,
                    .down => cursor = @min(cursor + 1, items.len - 1),
                    .ctrl_c => running = false,
                    .character => |c| if (c == 'q') {
                        running = false;
                    },
                    else => {},
                },
                .resize => {},
            }
            handled += 1;
            if (!running or handled == max_events_per_frame) break;
            pending = try ui.pollEvent();
        }
        if (running) try render(&ui, cursor);
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
```

Screen drawing functions return `void`. `present()` returns the first drawing
or output error. This keeps error handling out of layout code.

The application owns the loop. `nextEvent()` returns one event and blocks when
there is no input.

### Integration rules

- Keep one `Ui` alive for the terminal session and immediately `defer
  ui.deinit()` after initialization.
- Draw the complete logical frame between `begin()` and `present()`.
- After `nextEvent()`, use `pollEvent()` to apply queued input before rendering.
  Put a limit on each batch so continuous input cannot starve the display.
- Do not print directly to the active terminal or generate application-side
  ANSI sequences. Let `Screen` own terminal output.
- Handle `ctrl_c`; zooi returns it as a key instead of raising `SIGINT`.
- Propagate errors from `present()`. Install the restoration hook described in
  [Terminal restoration](#terminal-restoration) if the application can panic or
  handles fatal signals.

## API

### `Ui`

The terminal session.

```zig
pub fn init(gpa: Allocator, options: Options) !Ui
pub fn deinit(self: *Ui) void
pub fn screen(self: *Ui) *Screen
pub fn size(self: *const Ui) Size
pub fn nextEvent(self: *Ui) !?Event
pub fn pollEvent(self: *Ui) !?Event
```

`nextEvent` blocks until a key is pressed or the terminal is resized. It returns
`null` when the input stream ends. `pollEvent` returns a queued event without
blocking, or `null` if none is ready. Use it to process an input burst before
rendering once.

```zig
pub const Options = struct {
    /// Override the terminal descriptor. Null opens /dev/tty.
    tty: ?std.posix.fd_t = null,
    alternate_screen: bool = true,
    synchronized_output: bool = true,
    /// Compress long runs of styled spaces with REP. See Rendering model.
    repeat_sequences: bool = false,
    /// How long a lone ESC waits for the rest of a sequence.
    escape_timeout_ms: u16 = 25,
};
```

Input and output descriptors are selected separately. Input prefers a terminal
on stdin or stderr. Output prefers stdout, then stderr. `/dev/tty` is the
fallback. This prevents redirected output from receiving terminal control
sequences.

On macOS, `poll()` returns `POLLNVAL` for a newly opened `/dev/tty`. zooi
therefore prefers an inherited terminal for input. If both stdin and stderr are
redirected, `/dev/tty` input does not work on macOS. It works on Linux.

### `Event` and `Size`

```zig
pub const Event = union(enum) {
    key: Key,
    resize: Size,
};

pub const Size = struct { rows: u16, cols: u16 };
```

Repeated resize notifications are coalesced. No event is returned if the size
did not change. `rows` and `cols` may be `0`; rendering clips to the reported
size.

### `Key`

```zig
pub const Key = union(enum) {
    up, down, left, right,
    page_up, page_down, home, end,
    shift_up, shift_down,
    enter, escape, backspace, delete,
    tab, shift_tab,
    character: u21,
    ctrl_c,
};
```

`character` contains one printable Unicode codepoint decoded from UTF-8. Other
control bytes are dropped, Ctrl-Z among them; see [Non-goals](#non-goals).

zooi disables `ISIG`, so Ctrl-C is returned as `ctrl_c` instead of raising a
signal. Applications must handle it.

Both CSI (`ESC [ A`) and SS3 (`ESC O A`) forms are supported for arrows,
Home, and End. Shift-Tab is read from `ESC [ Z`.

### `Viewport`

`Viewport` provides allocation-free cursor and scroll-offset arithmetic for
lists. It does not consume keys, own application data, or render rows.

```zig
pub const Viewport = struct {
    cursor: usize = 0,
    offset: usize = 0,

    pub const Range = struct { start: usize, end: usize };

    pub fn normalize(self: *Viewport, item_count: usize, visible_rows: usize) void
    pub fn setCursor(self: *Viewport, index: usize, item_count: usize, visible_rows: usize) void
    pub fn move(self: *Viewport, delta: isize, item_count: usize, visible_rows: usize) void
    pub fn visibleRange(self: Viewport, item_count: usize, visible_rows: usize) Range
};
```

Movement clamps at both ends and adjusts `offset` only enough to keep the
cursor visible. An empty list resets both fields to zero. With zero visible
rows the cursor remains clamped, `offset` equals the cursor, and the returned
range is empty. `Range.end` is exclusive.

### `Screen`

```zig
pub fn begin(self: *Screen) void
pub fn move(self: *Screen, row: u16, col: u16) void
pub fn write(self: *Screen, text: []const u8) void
pub fn writeStyled(self: *Screen, text: []const u8, style: Style) void
pub fn clearToEndOfLine(self: *Screen) void
pub fn fillToEndOfLine(self: *Screen, style: Style) void
pub fn showCursor(self: *Screen, row: u16, col: u16) void
pub fn setSynchronizedOutput(self: *Screen, enabled: bool) void
pub fn setRepeatSequences(self: *Screen, enabled: bool) void
pub fn present(self: *Screen) !void
pub fn frame(self: *const Screen) []const u8

size: Size    // field: current terminal dimensions
```

Rows and columns are **0-based**. `begin()` starts a frame, `present()` writes
the changed cells to the terminal in a single write.

`showCursor` sets the cursor position for `present()`. If it is not called, the
cursor stays hidden.

`fillToEndOfLine` writes explicit spaces in the supplied style without moving
the logical cursor. Use it for full-width highlighted or colored rows.
`clearToEndOfLine` instead restores true blanks in the terminal's default
style.

### `Style` and `Color`

```zig
pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
};

pub const Color = union(enum) {
    ansi: u4,                                  // the terminal's own 16 colors
    indexed: u8,                               // 256-color palette
    rgb: struct { r: u8, g: u8, b: u8 },
};
```

`null` uses the terminal's default color. `.ansi` uses the terminal's configured
16-color palette.

### `testing`

The `zooi.testing` namespace provides a read-only view of the last successfully
presented logical frame:

```zig
pub const CellView = struct {
    text: []const u8,
    style: Style,
    columns: u2,
    continuation: bool,
};

pub fn presentedSize(screen: *const Screen) ?Size
pub fn inspectCell(screen: *const Screen, row: u16, col: u16) ?CellView
```

Both functions return `null` before a successful presentation or after a
failed one. `inspectCell` also returns `null` outside the presented size.
`CellView.text` borrows screen storage and must be consumed before the next
`present()` or `Screen.deinit()`.

### `displayWidth()`

```zig
pub fn displayWidth(text: []const u8) usize
```

Returns the number of terminal columns used by a string. For example, `é` uses
one column, `世` uses two, and a combining mark uses none. Width is calculated
per codepoint; see [Non-goals](#non-goals).

### `restore()`

```zig
pub fn restore() void
```

Restores terminal state. It is allocation-free, async-signal-safe, and does
nothing when no `Ui` is active. See [Terminal restoration](#terminal-restoration).

## Rendering model

Draw the full logical frame between `begin()` and `present()`. `Screen` compares
front and back cell grids and writes only changed row spans. Moving a cursor
usually updates two rows.

The grids, text storage, and ANSI output buffer are reused. Steady-state frames
do not allocate. A resize clears and repaints the screen once.

`begin()` captures `size` for the whole frame. A resize that arrives part-way
through — `pollEvent()` called mid-render, for instance — does not change the
geometry of the frame being drawn; it takes effect at the next `begin()`, which
repaints from a clear screen. Read `size` in `render` as usual.

A cell retains its base codepoint and up to 32 bytes of combining marks. Longer
runs of zero-width marks are dropped, so text from an untrusted source cannot
make one cell grow without bound.

To highlight a complete row, draw its text and then fill its remaining cells:

```zig
screen.writeStyled(label, selected_style);
screen.fillToEndOfLine(selected_style);
```

Long runs of styled spaces can be compressed into a REP sequence (`CSI Ps b`),
which saves under 100 bytes on a typical frame. It is off by default: a
terminal that does not implement REP drops the sequence silently and paints
styled backgrounds truncated to the width of their text. Set
`repeat_sequences = true` when the terminal is known to support it.

Synchronized output is enabled by default. Supporting terminals hold mode 2026
frames until `present()` writes the closing sequence. Other terminals normally
ignore the mode. Set `synchronized_output = false` if needed.

Clipping uses terminal columns, not byte length. Text past the right edge is
truncated. A wide character that would cross the edge is replaced with a space.
Writes outside the screen are ignored. Control bytes, malformed UTF-8, and
newlines are dropped.

The application decides how to handle a terminal that is too small.

## Terminal restoration

`deinit()` restores the alternate screen, cursor, and original termios:

```zig
var ui = try zooi.Ui.init(gpa, .{});
defer ui.deinit();
```

This handles normal returns and errors. For panics, call `restore()` from a
panic handler:

```zig
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, first_trace_addr: ?usize) noreturn {
        zooi.restore();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.f);
```

Call `restore()` from `SIGTERM` or `SIGHUP` handlers as well, if present.

## Testing without a terminal

Keep state changes in an `update` function and drawing in a `render` function.
Both can be tested without a terminal:

```zig
test "cursor stops at the end of the list" {
    var model: Model = .{ .cursor = 0, .items = &.{ "a", "b" } };
    update(&model, .{ .key = .down });
    update(&model, .{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), model.cursor);
}
```

`frame()` contains the ANSI bytes emitted by the most recent `present()`. Use it
for encoder assertions and to compare retained-diff size. The first frame
paints the screen; later frames contain only changes from the previous
successful frame.

For logical render assertions, inspect the last successfully presented frame:

```zig
const fd = try std.posix.openatZ(
    std.posix.AT.FDCWD,
    "/dev/null",
    .{ .ACCMODE = .WRONLY },
    0,
);
defer _ = std.posix.system.close(fd);

var screen = zooi.Screen.init(std.testing.allocator, fd, .{ .rows = 3, .cols = 20 });
defer screen.deinit();
screen.begin();
screen.writeStyled("selected", .{ .reverse = true });
screen.fillToEndOfLine(.{ .reverse = true });
try screen.present();

const cell = zooi.testing.inspectCell(&screen, 0, 19).?;
try std.testing.expectEqualStrings(" ", cell.text);
try std.testing.expect(cell.style.reverse);
```

The returned text is borrowed; assert on it before the next `present()`. Keep
application state in the model: production layout, navigation, and event
handling should not read values back from the screen.

Terminal behaviour itself needs a real terminal, and that is the one place
where unit tests cannot help. zooi's own suite covers it in
[`test/pty_test.zig`](test/pty_test.zig): raw-mode lifecycle, alternate-screen
lifecycle, key decoding through a pty, escape timing in both directions,
resize delivery and coalescing, and restoration after `SIGTERM` and after a
panic. [`test/pty.zig`](test/pty.zig) is the harness, and it is worth copying
the one rule it follows — every wait is for a marker the program emits, never
for a duration. A terminal suite built on sleeps is one everybody learns to
ignore.

## Platform support

| Platform | Status | libc |
|---|---|---|
| Linux x86_64 | verified on hardware, and on every CI run | none |
| Linux aarch64 | builds | none |
| macOS aarch64 / x86_64 | verified | `libSystem` (unavoidable) |

`zig build verify` builds a standalone binary that checks zooi's primitives
against the machine it runs on and reports PASS/FAIL per check. CI runs it on
Linux under a pty, built for `x86_64-linux-none`, so each push proves the
libc-free build both links and runs. On an unusual terminal, run it and paste
the output.

Cross-compiling requires only Zig:

```sh
zig build -Dtarget=x86_64-linux-none      # static, no libc
zig build -Dtarget=aarch64-macos
```

The target ABI does not enable libc by itself. `-lc` or `linkLibC()` enables it.
For example, `-Dtarget=x86_64-linux-gnu` without `-lc` is libc-free.

## Non-goals

zooi does not provide widgets, layout containers, focus management, mouse or
clipboard input, terminal graphics, async jobs, background workers, filesystem
watching, plugins, themes, configurable key bindings, or multiple panes.

Known limits:

- **Unicode width is per-codepoint.** Combining marks and East Asian widths are
  handled; grapheme clusters, ZWJ emoji sequences, and variation selectors are
  not. A family emoji built from several people and ZWJs will measure wrong.
- **The retained grid is not application state.** Tests can inspect the last
  successfully presented frame through a read-only diagnostic view, but
  production code should not recover its model from rendered cells.
- **Single-threaded.** All rendering and all state changes happen on the loop.
- **No job control.** `ISIG` is off and Ctrl-Z is not delivered as a key, so a
  zooi application cannot be suspended and resumed.

## Versioning

0.1.0 was the first release. The API may change before 1.0.0. Pin the `v0.1.3`
tag for reproducible builds.

## License

MIT. See [LICENSE](LICENSE).
