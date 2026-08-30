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
zig fetch --save git+https://github.com/vrypan/zooi.git#v0.1.1
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

The public API has nine items.

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

### `Screen`

```zig
pub fn begin(self: *Screen) void
pub fn move(self: *Screen, row: u16, col: u16) void
pub fn write(self: *Screen, text: []const u8) void
pub fn writeStyled(self: *Screen, text: []const u8, style: Style) void
pub fn clearToEndOfLine(self: *Screen) void
pub fn showCursor(self: *Screen, row: u16, col: u16) void
pub fn setSynchronizedOutput(self: *Screen, enabled: bool) void
pub fn setRepeatSequences(self: *Screen, enabled: bool) void
pub fn present(self: *Screen) !void

size: Size    // field: current terminal dimensions
```

Rows and columns are **0-based**. `begin()` starts a frame, `present()` writes
the changed cells to the terminal in a single write.

`showCursor` sets the cursor position for `present()`. If it is not called, the
cursor stays hidden.

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

Render at a fixed size and inspect `frame()` to test output, including sizes
such as `0 × 0`. `frame()` contains the ANSI bytes from the most recent
`present()`. The first frame paints the screen; later frames contain changes
from the previous successful frame. Use the same `Screen` for successive
models when testing retained rendering.

Use PTY tests for raw mode, the alternate screen, resize events, and restoration.

## Platform support

| Platform | Status | libc |
|---|---|---|
| Linux x86_64 | verified on hardware | none |
| Linux aarch64 | builds | none |
| macOS aarch64 / x86_64 | verified | `libSystem` (unavoidable) |

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
- **The retained grid is not application state.** It cannot be queried.
- **Single-threaded.** All rendering and all state changes happen on the loop.
- **No job control.** `ISIG` is off and Ctrl-Z is not delivered as a key, so a
  zooi application cannot be suspended and resumed.

## Versioning

0.1.0 was the first release. The API may change before 1.0.0. Pin the `v0.1.1`
tag for reproducible builds.

## License

MIT. See [LICENSE](LICENSE).
