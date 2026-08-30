# zooi

> [!WARNING]
> **NOT YET IMPLEMENTED**
>
> This document is the design contract for zooi v0.1.0, written before the
> code. Nothing here is fetchable yet, and details may change as it is built.

A small Zig library for building keyboard-driven, full-screen terminal
programs. It owns the terminal — raw mode, the alternate screen, resize
notification, key decoding, and a buffered frame — and nothing else. Your
application owns its state, its key bindings, and its rendering.

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

## Is zooi the right choice?

zooi is deliberately small. It gives you an event loop, a screen buffer, and
styled text. That is the whole library.

**Use zooi if** you are building something like a list browser, a picker, a log
viewer, or a small dashboard: one screen, keyboard input, full redraws, and you
would rather write your own layout than learn someone else's.

**Use [libvaxis](https://github.com/rockorager/libvaxis) instead if** you need a
widget tree, a layout engine, mouse interaction, terminal graphics, capability
negotiation, or a component ecosystem. zooi does not compete with it and will
not grow toward it — see [Non-goals](#non-goals).

zooi should stay small enough that you can read the library itself when its
behavior surprises you.

## Requirements

- Zig **0.16.0**
- No third-party dependencies, ever
- **No libc on Linux.** Every syscall goes through `std.posix`, or through raw
  `std.os.linux` syscalls where 0.16's `std.posix` has no wrapper. On macOS,
  `libSystem` is linked because Apple provides no other supported interface.

zooi never calls `linkLibC()` itself. If your program links libc for its own
reasons, zooi follows that choice rather than overriding it.

## Install

Add the dependency:

```sh
zig fetch --save git+https://github.com/vrypan/zooi.git#v0.1.0
```

Then wire it into `build.zig`:

```zig
const zooi = b.dependency("zooi", .{});
exe.root_module.addImport("zooi", zooi.module("zooi"));
```

To vendor instead, copy `src/` and point a module at `src/zooi.zig`. There are
no dependencies to bring along.

## Quick start

A complete program. It draws a list, moves a cursor, and quits on `q`:

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
    render(&ui, cursor);

    while (try ui.nextEvent()) |event| {
        switch (event) {
            .key => |key| switch (key) {
                .up => cursor -|= 1,
                .down => cursor = @min(cursor + 1, items.len - 1),
                .ctrl_c => break,
                .character => |c| if (c == 'q') break,
                else => {},
            },
            .resize => {},
        }
        render(&ui, cursor);
    }
}

fn render(ui: *zooi.Ui, cursor: usize) void {
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
    screen.present() catch {};
}
```

Two things to notice, because they shape everything else:

`render` returns `void` and takes no error. Screen writes cannot fail
individually — the first failure is recorded and returned by `present()`. That
keeps layout code free of `try` on every line and, more importantly, makes
`render` callable from a unit test with no terminal and no error handling.

The loop is yours. zooi hands you one event at a time and blocks in between; it
never calls you back and never owns your control flow.

## API

Eight public items.

### `Ui`

The terminal session.

```zig
pub fn init(gpa: Allocator, options: Options) !Ui
pub fn deinit(self: *Ui) void
pub fn screen(self: *Ui) *Screen
pub fn size(self: *const Ui) Size
pub fn nextEvent(self: *Ui) !?Event
```

`nextEvent` blocks until a key is pressed or the terminal is resized. It
returns `null` when the input stream ends, which for a terminal means the
session is over.

```zig
pub const Options = struct {
    /// Override the terminal descriptor. Null opens /dev/tty.
    tty: ?std.posix.fd_t = null,
    alternate_screen: bool = true,
    /// How long a lone ESC waits for the rest of a sequence.
    escape_timeout_ms: u16 = 25,
};
```

zooi opens `/dev/tty` rather than using stdout, so `yourprog > log` and
`yourprog | head` do not paint the interface into a pipe or read keystrokes
from a file.

### `Event` and `Size`

```zig
pub const Event = union(enum) {
    key: Key,
    resize: Size,
};

pub const Size = struct { rows: u16, cols: u16 };
```

Resize events are coalesced: dragging a window emits one event per settled
size, not one per notification, and no event at all if the size did not
actually change. Both `rows` and `cols` may legitimately be `0` on some
terminals — zooi reports the truth and clips accordingly rather than pretending
otherwise.

### `Key`

```zig
pub const Key = union(enum) {
    up, down, left, right,
    page_up, page_down, home, end,
    shift_up, shift_down,
    enter, escape, backspace, delete,
    character: u21,
    ctrl_c,
};
```

`character` is printable text only, decoded from UTF-8, so a prompt can append
it to a buffer without filtering. Control bytes other than the ones named above
are dropped rather than surfaced.

**`ctrl_c` is a key, not a signal.** zooi disables `ISIG`, so Ctrl-C arrives
here for you to interpret. Handle it or your program cannot be quit that way.

Both `ESC [ A` and `ESC O A` forms are decoded for arrows and Home/End, because
terminals disagree, and a multiplexer may leave cursor-key application mode set
even though zooi never enables it.

### `Screen`

```zig
pub fn begin(self: *Screen) void
pub fn move(self: *Screen, row: u16, col: u16) void
pub fn write(self: *Screen, text: []const u8) void
pub fn writeStyled(self: *Screen, text: []const u8, style: Style) void
pub fn clearToEndOfLine(self: *Screen) void
pub fn showCursor(self: *Screen, row: u16, col: u16) void
pub fn present(self: *Screen) !void

size: Size    // field: current terminal dimensions
```

Rows and columns are **0-based**. `begin()` starts a frame, `present()` writes
it to the terminal in a single write.

`showCursor` marks where the terminal cursor should be left when the frame is
presented — use it for text prompts. A frame that never calls it presents with
the cursor hidden.

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

`null` means the terminal's default, which is not the same as any specific
color. Prefer `.ansi` where you can: it respects the palette the user chose.

### `restore()`

```zig
pub fn restore() void
```

Restores the terminal from a panic handler or a fatal-signal handler.
Allocation-free, async-signal-safe, and a no-op when no `Ui` is active. See
[Terminal restoration](#terminal-restoration).

## Rendering model

Redraw everything, every frame. There is no diff, no back buffer, and no cell
grid — `Screen` appends ANSI bytes to one reusable buffer and flushes it in a
single write. A terminal holds little enough data that this is fast, and it
removes an entire class of stale-cell bugs.

The buffer is reused between frames, so steady-state rendering does not
allocate.

**Clipping is automatic and measured in columns, not bytes.** Text is truncated
to the terminal width using display width, so `é` counts as one column and `世`
as two. A wide character that would straddle the right edge is dropped and the
leftover column is filled with a space, because emitting half of one corrupts
the terminal's own column tracking for the rest of the line. Writes to rows
beyond the screen produce nothing. Control bytes and newlines in your text are
dropped — a string from an external source cannot break the frame.

You still decide what to do when the terminal is too small. zooi guarantees
only that it will clip rather than fail; showing a "window too small" message
is your call.

## Terminal restoration

Leaving a user's shell in raw mode with no echo is the worst thing a TUI can
do, so this is treated as a correctness requirement rather than a nicety.

`deinit()` restores everything — the alternate screen, the cursor, and the
original termios — and is safe on every error path:

```zig
var ui = try zooi.Ui.init(gpa, .{});
defer ui.deinit();
```

That covers normal returns and errors. It does **not** cover panics or fatal
signals, and zooi deliberately does not install handlers for those: choosing a
signal policy is a program-wide decision a library should not make for you.
Wire it up yourself:

```zig
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, first_trace_addr: ?usize) noreturn {
        zooi.restore();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.f);
```

Do the same from a `SIGTERM` or `SIGHUP` handler if your program handles them.

## Testing without a terminal

Most of a TUI's behavior is a pure function, and zooi is shaped so you can test
it that way. Keep your state transitions in an `update` function and your
drawing in a `render` function, and neither needs a terminal:

```zig
test "cursor stops at the end of the list" {
    var model: Model = .{ .cursor = 0, .items = &.{ "a", "b" } };
    update(&model, .{ .key = .down });
    update(&model, .{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), model.cursor);
}
```

Because `render` cannot fail and takes a `*Screen`, you can render a model at a
fixed size and assert on the bytes produced — including at awkward sizes like
`0 × 0` — without opening a terminal at all.

That leaves genuinely terminal-specific behavior (raw mode, alternate screen,
resize, restoration) for a PTY test, which is a much smaller set.

## Platform support

| Platform | Status | libc |
|---|---|---|
| Linux x86_64 | verified on hardware | none |
| Linux aarch64 | builds | none |
| macOS aarch64 / x86_64 | verified | `libSystem` (unavoidable) |

Cross-compiling needs nothing but Zig — no sysroot, no toolchain, no libc
headers:

```sh
zig build -Dtarget=x86_64-linux-none      # static, no libc
zig build -Dtarget=aarch64-macos
```

The ABI in a target triple does not decide libc linkage; `-lc` and
`linkLibC()` do. `-Dtarget=x86_64-linux-gnu` without `-lc` is equally libc-free.
`-none` is simply the spelling that cannot be weakened later.

## Non-goals

zooi will not grow a widget hierarchy, layout containers, focus propagation,
mouse support, clipboard integration, terminal graphics, async jobs, background
workers, filesystem watching, plugins, configurable themes, user-defined
keybindings, diff-based rendering, or multiple panes.

Known limits worth stating plainly:

- **Unicode width is per-codepoint.** Combining marks and East Asian widths are
  handled; grapheme clusters, ZWJ emoji sequences, and variation selectors are
  not. A family emoji built from several people and ZWJs will measure wrong.
- **No cell grid**, so there is nothing to query about what is currently on
  screen. Your model is the source of truth.
- **Single-threaded.** All rendering and all state changes happen on the loop.

If you need something on that list, you have outgrown zooi, and that is a fine
outcome — reach for libvaxis.

## Versioning

v0.1.0 is a first release with one consumer that has not yet used it in anger.
The API may move before v1.0.0. Pin a tag.

## License

To be added with the first release.
