//! A journal browser built on zooi.
//!
//! This exists to prove the library's API is sufficient for a real interface
//! before a real consumer depends on it. It reproduces the layout and the
//! interactions from the zooi spec — navigation, single and range selection,
//! pin, tag, name, delete-with-confirmation, and inspect — over a fake
//! in-memory list. There is no journal, no filesystem, and no persistence:
//! zooi owns the terminal, this owns everything else.
//!
//! The architecture is the one the spec describes and zooi supports without
//! enforcing:
//!
//!     Msg -> update(model, msg) -> Model + Effect -> render(model)
//!
//! `update` mutates UI state and returns an effect; effects are executed
//! separately. That split is what keeps every state transition testable
//! without a terminal — see browser_test.zig.

const std = @import("std");
const zooi = @import("zooi");

// --- fake data ---------------------------------------------------------------

const max_entries = 100;
const text_max = 48;

pub const Entry = struct {
    number: u32,
    status: u8,
    command: []const u8,
    pinned: bool = false,
    name_buf: [text_max]u8 = undefined,
    name_len: usize = 0,
    tag_buf: [text_max]u8 = undefined,
    tag_len: usize = 0,

    pub fn name(self: *const Entry) ?[]const u8 {
        return if (self.name_len == 0) null else self.name_buf[0..self.name_len];
    }
    pub fn tag(self: *const Entry) ?[]const u8 {
        return if (self.tag_len == 0) null else self.tag_buf[0..self.tag_len];
    }
};

/// Command templates are repeated with distinct entry numbers to keep the
/// source readable while providing enough rows to demonstrate the viewport on
/// a tall terminal. The set deliberately includes wide and combining text.
const seed = [_]struct { status: u8, command: []const u8 }{
    .{ .status = 0, .command = "git status" },
    .{ .status = 0, .command = "zig build test" },
    .{ .status = 1, .command = "zig build" },
    .{ .status = 0, .command = "git diff --stat" },
    .{ .status = 0, .command = "make check" },
    .{ .status = 0, .command = "git commit -m \"wire up the parser\"" },
    .{ .status = 130, .command = "cargo build --release" },
    .{ .status = 0, .command = "echo 世界 — wide characters" },
    .{ .status = 0, .command = "echo café  (combining accent)" },
    .{ .status = 0, .command = "grep -rn TODO src/" },
    .{ .status = 2, .command = "curl -sS https://example.com/api" },
    .{ .status = 0, .command = "docker compose up -d" },
    .{ .status = 0, .command = "psql -c 'select count(*) from events'" },
    .{ .status = 0, .command = "rsync -a ./dist/ server:/srv/www/" },
    .{ .status = 0, .command = "kubectl get pods -A" },
    .{ .status = 1, .command = "npm test -- --watch=false" },
    .{ .status = 0, .command = "tar -czf backup.tgz ~/Documents" },
    .{ .status = 0, .command = "ssh build@ci 'uptime'" },
    .{ .status = 0, .command = "python3 -m http.server 8000" },
    .{ .status = 0, .command = "brew upgrade" },
};

// --- model -------------------------------------------------------------------

pub const Selection = union(enum) {
    none,
    single: usize,
    range: struct { anchor: usize, cursor: usize },

    /// Normalised, inclusive. Callers ask for this rather than reading the
    /// anchor directly, because the anchor may be below the cursor.
    pub fn bounds(self: Selection) ?struct { lo: usize, hi: usize } {
        return switch (self) {
            .none => null,
            .single => |i| .{ .lo = i, .hi = i },
            .range => |r| .{
                .lo = @min(r.anchor, r.cursor),
                .hi = @max(r.anchor, r.cursor),
            },
        };
    }

    pub fn contains(self: Selection, i: usize) bool {
        const b = self.bounds() orelse return false;
        return i >= b.lo and i <= b.hi;
    }

    pub fn count(self: Selection) usize {
        const b = self.bounds() orelse return 0;
        return b.hi - b.lo + 1;
    }
};

pub const Prompt = struct {
    buf: [text_max]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Prompt) []const u8 {
        return self.buf[0..self.len];
    }

    fn push(self: *Prompt, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (self.len + n > self.buf.len) return;
        @memcpy(self.buf[self.len..][0..n], tmp[0..n]);
        self.len += n;
    }

    /// Removes a whole codepoint, not a byte: backspacing an accented
    /// character must not leave half of it behind.
    fn pop(self: *Prompt) void {
        if (self.len == 0) return;
        var i = self.len - 1;
        while (i > 0 and (self.buf[i] & 0xc0) == 0x80) i -= 1;
        self.len = i;
    }
};

pub const Mode = union(enum) {
    normal,
    tag_input: Prompt,
    name_input: Prompt,
    delete_confirm,
    inspect,
};

pub const Effect = union(enum) {
    none,
    quit,
    refresh,
    toggle_pin,
    set_tag,
    set_name,
    delete,
};

pub const Msg = union(enum) {
    terminal: zooi.Event,
    /// Emitted after an effect changes the data, exactly as the spec's
    /// journal_updated does.
    data_changed,
};

pub const Model = struct {
    entries: [max_entries]Entry = undefined,
    count: usize = 0,
    viewport: zooi.Viewport = .{},
    selection: Selection = .none,
    mode: Mode = .normal,
    size: zooi.Size = .{ .rows = 24, .cols = 80 },
    status_buf: [128]u8 = undefined,
    status_len: usize = 0,
    /// Text carried from a prompt to the effect executor. Valid until the
    /// next update.
    pending: [text_max]u8 = undefined,
    pending_len: usize = 0,
    quit: bool = false,

    pub fn init() Model {
        var m: Model = .{};
        for (0..max_entries) |i| {
            const s = seed[i % seed.len];
            m.entries[i] = .{
                .number = @intCast(i + 24),
                .status = s.status,
                .command = s.command,
            };
        }
        m.count = max_entries;
        m.entries[3].pinned = true;
        return m;
    }

    pub fn status(self: *const Model) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    fn setStatus(self: *Model, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status_buf, fmt, args) catch {
            self.status_len = 0;
            return;
        };
        self.status_len = s.len;
    }

    fn setPending(self: *Model, text: []const u8) void {
        const n = @min(text.len, self.pending.len);
        @memcpy(self.pending[0..n], text[0..n]);
        self.pending_len = n;
    }

    /// Rows available for the list: everything but the header and footer.
    pub fn listRows(self: *const Model) usize {
        if (self.size.rows < 3) return 0;
        return self.size.rows - 2;
    }

    /// The spec's rule for every mutation: the selection if there is one,
    /// otherwise the cursor entry.
    fn target(self: *const Model) struct { lo: usize, hi: usize } {
        if (self.selection.bounds()) |b| return .{ .lo = b.lo, .hi = b.hi };
        return .{ .lo = self.viewport.cursor, .hi = self.viewport.cursor };
    }
};

// --- update ------------------------------------------------------------------

pub fn update(m: *Model, msg: Msg) Effect {
    switch (msg) {
        .data_changed => {
            normalise(m);
            return .none;
        },
        .terminal => |event| switch (event) {
            .resize => |size| {
                m.size = size;
                m.viewport.normalize(m.count, m.listRows());
                return .none;
            },
            .key => |key| return onKey(m, key),
        },
    }
}

fn onKey(m: *Model, key: zooi.Key) Effect {
    // Ctrl-C is a key, not a signal: raw mode disabled ISIG, so quitting is
    // this program's responsibility.
    if (key == .ctrl_c) {
        m.quit = true;
        return .quit;
    }

    return switch (m.mode) {
        .normal => normalKey(m, key),
        .tag_input => |*p| promptKey(m, key, p, .set_tag),
        .name_input => |*p| promptKey(m, key, p, .set_name),
        .delete_confirm => confirmKey(m, key),
        .inspect => inspectKey(m, key),
    };
}

fn normalKey(m: *Model, key: zooi.Key) Effect {
    const last = if (m.count == 0) 0 else m.count - 1;
    const page = @max(m.listRows(), 1);

    switch (key) {
        .up => moveCursor(m, -1),
        .down => moveCursor(m, 1),
        .page_up => moveCursor(m, -@as(isize, @intCast(page))),
        .page_down => moveCursor(m, @intCast(page)),
        .home => setCursor(m, 0),
        .end => setCursor(m, last),

        // Shift+Arrow extends a range. The v-anchor scheme below does the
        // same thing for terminals that do not send modifiers.
        .shift_up => extend(m, -1),
        .shift_down => extend(m, 1),

        .escape => {
            m.selection = .none;
            m.setStatus("", .{});
        },

        .enter => {
            if (m.count > 0) m.mode = .inspect;
        },

        .character => |cp| switch (cp) {
            'k' => moveCursor(m, -1),
            'j' => moveCursor(m, 1),
            'g' => setCursor(m, 0),
            'G' => setCursor(m, last),
            'q' => {
                m.quit = true;
                return .quit;
            },
            'r' => {
                m.setStatus("refreshed", .{});
                return .refresh;
            },
            ' ' => {
                toggleSelect(m);
                return .none;
            },
            'v' => {
                m.selection = .{ .range = .{
                    .anchor = m.viewport.cursor,
                    .cursor = m.viewport.cursor,
                } };
                m.setStatus("range selection started", .{});
            },
            'p' => {
                if (m.count == 0) return .none;
                return .toggle_pin;
            },
            't' => {
                if (m.count == 0) return .none;
                m.mode = .{ .tag_input = .{} };
            },
            'n' => {
                if (m.count == 0) return .none;
                // Naming applies to exactly one entry. With a multi-entry
                // selection the cursor entry wins, and the status line says
                // so rather than leaving it ambiguous.
                if (m.selection.count() > 1)
                    m.setStatus("naming applies to the cursor entry only", .{});
                m.mode = .{ .name_input = .{} };
            },
            'd' => {
                if (m.count == 0) return .none;
                m.mode = .delete_confirm;
            },
            else => {},
        },
        else => {},
    }
    return .none;
}

fn promptKey(m: *Model, key: zooi.Key, p: *Prompt, effect: Effect) Effect {
    switch (key) {
        .escape => {
            m.mode = .normal;
            m.setStatus("cancelled", .{});
        },
        .enter => {
            if (p.len == 0) {
                m.mode = .normal;
                m.setStatus("cancelled: empty", .{});
                return .none;
            }
            m.setPending(p.text());
            m.mode = .normal;
            return effect;
        },
        .backspace => p.pop(),
        .character => |cp| p.push(cp),
        else => {},
    }
    return .none;
}

fn confirmKey(m: *Model, key: zooi.Key) Effect {
    // The default answer is no: only an explicit y confirms.
    switch (key) {
        .character => |cp| if (cp == 'y' or cp == 'Y') {
            m.mode = .normal;
            return .delete;
        },
        else => {},
    }
    m.mode = .normal;
    m.setStatus("delete cancelled", .{});
    return .none;
}

fn inspectKey(m: *Model, key: zooi.Key) Effect {
    switch (key) {
        .escape, .enter => m.mode = .normal,
        .character => |cp| if (cp == 'q') {
            m.mode = .normal;
        },
        else => {},
    }
    return .none;
}

fn setCursor(m: *Model, i: usize) void {
    m.viewport.setCursor(i, m.count, m.listRows());
    if (m.count > 0 and m.selection == .range)
        m.selection.range.cursor = m.viewport.cursor;
}

fn moveCursor(m: *Model, delta: isize) void {
    m.viewport.move(delta, m.count, m.listRows());
    if (m.count > 0 and m.selection == .range)
        m.selection.range.cursor = m.viewport.cursor;
}

fn extend(m: *Model, delta: isize) void {
    if (m.count == 0) return;
    if (m.selection != .range) {
        m.selection = .{ .range = .{
            .anchor = m.viewport.cursor,
            .cursor = m.viewport.cursor,
        } };
    }
    moveCursor(m, delta);
}

fn toggleSelect(m: *Model) void {
    if (m.count == 0) return;
    switch (m.selection) {
        .single => |i| if (i == m.viewport.cursor) {
            m.selection = .none;
        } else {
            m.selection = .{ .single = m.viewport.cursor };
        },
        else => m.selection = .{ .single = m.viewport.cursor },
    }
}

/// After entries disappear, the cursor and selection may point past the end.
fn normalise(m: *Model) void {
    if (m.count == 0) {
        m.viewport.normalize(0, m.listRows());
        m.selection = .none;
        return;
    }
    m.viewport.normalize(m.count, m.listRows());
    if (m.selection.bounds()) |b| {
        if (b.hi >= m.count) m.selection = .none;
    }
}

// --- effects -----------------------------------------------------------------

/// Executed synchronously, and may produce a follow-up message. In a real
/// consumer this is where the domain layer would be called.
pub fn executeEffect(m: *Model, effect: Effect) ?Msg {
    switch (effect) {
        .none, .quit => return null,
        .refresh => return .data_changed,

        .toggle_pin => {
            const t = m.target();
            var i = t.lo;
            while (i <= t.hi) : (i += 1) m.entries[i].pinned = !m.entries[i].pinned;
            m.setStatus("pinned/unpinned {d} entr{s}", .{
                t.hi - t.lo + 1,
                if (t.hi == t.lo) "y" else "ies",
            });
            return .data_changed;
        },

        .set_tag => {
            const t = m.target();
            const text = m.pending[0..m.pending_len];
            var i = t.lo;
            while (i <= t.hi) : (i += 1) {
                const n = @min(text.len, text_max);
                @memcpy(m.entries[i].tag_buf[0..n], text[0..n]);
                m.entries[i].tag_len = n;
            }
            m.setStatus("tagged {d} with \"{s}\"", .{ t.hi - t.lo + 1, text });
            return .data_changed;
        },

        .set_name => {
            const text = m.pending[0..m.pending_len];
            // Uniqueness is a domain rule; rejecting here shows how an
            // operational error becomes a status message rather than an exit.
            for (m.entries[0..m.count], 0..) |*e, i| {
                if (i != m.viewport.cursor and e.name() != null and
                    std.mem.eql(u8, e.name().?, text))
                {
                    m.setStatus("name \"{s}\" is already taken", .{text});
                    return null;
                }
            }
            const n = @min(text.len, text_max);
            @memcpy(m.entries[m.viewport.cursor].name_buf[0..n], text[0..n]);
            m.entries[m.viewport.cursor].name_len = n;
            m.setStatus("named entry {d} \"{s}\"", .{
                m.entries[m.viewport.cursor].number,
                text,
            });
            return .data_changed;
        },

        .delete => {
            const t = m.target();
            // Pinned entries are protected, which is the kind of domain rule
            // that must surface as a message rather than a failure.
            var i = t.lo;
            while (i <= t.hi) : (i += 1) {
                if (m.entries[i].pinned) {
                    m.setStatus("entry {d} is pinned; not deleted", .{m.entries[i].number});
                    return null;
                }
            }
            const n = t.hi - t.lo + 1;
            var j = t.lo;
            while (j + n < m.count) : (j += 1) m.entries[j] = m.entries[j + n];
            m.count -= n;
            m.selection = .none;
            m.setStatus("deleted {d} entr{s}", .{ n, if (n == 1) "y" else "ies" });
            return .data_changed;
        },
    }
}

// --- render ------------------------------------------------------------------

const header_style: zooi.Style = .{ .reverse = true, .bold = true };
const footer_style: zooi.Style = .{ .dim = true };
const cursor_style: zooi.Style = .{ .reverse = true };
const selected_style: zooi.Style = .{ .fg = .{ .ansi = 6 } };
const both_style: zooi.Style = .{ .reverse = true, .fg = .{ .ansi = 6 } };
const fail_style: zooi.Style = .{ .fg = .{ .ansi = 1 } };
const meta_style: zooi.Style = .{ .fg = .{ .ansi = 4 } };

/// Test affordance, not a library feature: with `ZOOI_EXAMPLE_MARKERS` set,
/// announce every painted frame on stderr. The PTY suite waits for a marker
/// instead of sleeping, which is the whole difference between a terminal test
/// that can be trusted and one that cannot. Stderr, never stdout — stdout is
/// the interface under test.
var markers_enabled: bool = false;
var frames_painted: usize = 0;

fn finishFrame(screen: *zooi.Screen) void {
    screen.present() catch {};
    frames_painted += 1;
    if (markers_enabled) std.debug.print("[zooi-frame {d}]\n", .{frames_painted});
}

pub fn render(m: *const Model, screen: *zooi.Screen) void {
    screen.begin();

    // Too small to be useful: say so rather than drawing a broken frame.
    if (m.size.rows < 3 or m.size.cols < 20) {
        screen.move(0, 0);
        screen.write("terminal too small");
        finishFrame(screen);
        return;
    }

    if (m.mode == .inspect) {
        renderInspect(m, screen);
        finishFrame(screen);
        return;
    }

    renderHeader(m, screen);
    renderList(m, screen);
    renderFooter(m, screen);
    finishFrame(screen);
}

fn renderHeader(m: *const Model, screen: *zooi.Screen) void {
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, " zooi browser  {d} entries  {d}x{d} ", .{
        m.count, m.size.rows, m.size.cols,
    }) catch " zooi browser ";
    screen.move(0, 0);
    screen.writeStyled(text, header_style);
    screen.fillToEndOfLine(header_style);
}

fn renderList(m: *const Model, screen: *zooi.Screen) void {
    const rows = m.listRows();
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        const idx = m.viewport.offset + row;
        screen.move(@intCast(row + 1), 0);
        if (idx >= m.count) continue;

        const e = &m.entries[idx];
        const is_cursor = idx == m.viewport.cursor;
        const is_selected = m.selection.contains(idx);

        // The four states the spec calls for.
        const style: zooi.Style = if (is_cursor and is_selected)
            both_style
        else if (is_cursor)
            cursor_style
        else if (is_selected)
            selected_style
        else
            .{};

        // Reverse video must cover the row, not stop after the command text.
        // Prefill before drawing content so reverse video reaches the edge.
        if (is_cursor) screen.fillToEndOfLine(style);

        var buf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "{s}{s}{s} {d: >4} ", .{
            if (is_cursor) ">" else " ",
            if (is_selected) "*" else " ",
            if (e.pinned) "@" else " ",
            e.number,
        }) catch "  ";
        screen.writeStyled(head, style);

        var sbuf: [8]u8 = undefined;
        const st = std.fmt.bufPrint(&sbuf, "{d: >3} ", .{e.status}) catch "  0 ";
        screen.writeStyled(st, if (e.status != 0 and !is_cursor) fail_style else style);

        if (e.name()) |n| {
            screen.writeStyled(n, if (is_cursor) style else meta_style);
            screen.writeStyled(" ", style);
        }
        if (e.tag()) |t| {
            var tbuf: [64]u8 = undefined;
            const tag = std.fmt.bufPrint(&tbuf, "#{s} ", .{t}) catch "# ";
            screen.writeStyled(tag, if (is_cursor) style else meta_style);
        }
        screen.writeStyled(e.command, style);
    }
}

fn renderFooter(m: *const Model, screen: *zooi.Screen) void {
    const row: u16 = @intCast(m.size.rows - 1);
    screen.move(row, 0);

    switch (m.mode) {
        .tag_input => |p| {
            screen.write("tag: ");
            screen.write(p.text());
            // The prompt is why showCursor exists.
            screen.showCursor(row, @intCast(5 + zooi.displayWidth(p.text())));
            return;
        },
        .name_input => |p| {
            screen.write("name: ");
            screen.write(p.text());
            screen.showCursor(row, @intCast(6 + zooi.displayWidth(p.text())));
            return;
        },
        .delete_confirm => {
            const t = m.target();
            var buf: [128]u8 = undefined;
            const text = if (t.lo == t.hi)
                std.fmt.bufPrint(&buf, "Delete entry {d}? [y/N] ", .{
                    m.entries[t.lo].number,
                }) catch "Delete? [y/N] "
            else
                std.fmt.bufPrint(&buf, "Delete entries {d}-{d}? [y/N] ", .{
                    m.entries[t.lo].number, m.entries[t.hi].number,
                }) catch "Delete? [y/N] ";
            screen.writeStyled(text, .{ .bold = true });
            return;
        },
        else => {},
    }

    if (m.status_len > 0) {
        screen.writeStyled(m.status(), .{ .fg = .{ .ansi = 3 } });
        return;
    }
    screen.writeStyled(
        "↑↓ move  space select  v range  p pin  t tag  n name  d del  ⏎ inspect  r refresh  q quit",
        footer_style,
    );
}

fn renderInspect(m: *const Model, screen: *zooi.Screen) void {
    const e = &m.entries[m.viewport.cursor];
    screen.move(0, 0);
    screen.writeStyled(" inspect ", header_style);

    var line: u16 = 2;
    const put = struct {
        fn f(s: *zooi.Screen, r: u16, label: []const u8, value: []const u8) void {
            s.move(r, 2);
            s.writeStyled(label, meta_style);
            s.move(r, 14);
            s.write(value);
        }
    }.f;

    var buf: [64]u8 = undefined;
    put(screen, line, "command", e.command);
    line += 1;
    put(screen, line, "number", std.fmt.bufPrint(&buf, "{d}", .{e.number}) catch "?");
    line += 1;
    var sbuf: [64]u8 = undefined;
    put(screen, line, "exit status", std.fmt.bufPrint(&sbuf, "{d}", .{e.status}) catch "?");
    line += 1;
    put(screen, line, "name", e.name() orelse "-");
    line += 1;
    put(screen, line, "tag", e.tag() orelse "-");
    line += 1;
    put(screen, line, "pinned", if (e.pinned) "yes" else "no");

    screen.move(@intCast(m.size.rows - 1), 0);
    screen.writeStyled("esc / q / \u{23ce} to close", footer_style);
}

// --- main --------------------------------------------------------------------

/// Restore the terminal before the default panic handler prints anything.
/// zooi does not install this itself: choosing a process-wide policy is the
/// application's decision.
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, first_trace_addr: ?usize) noreturn {
        zooi.restore();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.f);

fn onTerm(_: std.posix.SIG) callconv(.c) void {
    zooi.restore();
    std.process.exit(130);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug.deinit();
    const gpa = debug.allocator();

    markers_enabled = init.environ.getPosix("ZOOI_EXAMPLE_MARKERS") != null;

    var ui = zooi.Ui.init(gpa, .{}) catch |err| {
        std.debug.print("zooi: {s}\n", .{@errorName(err)});
        std.debug.print("Run this in a terminal.\n", .{});
        return;
    };
    defer ui.deinit();

    // Same pattern the README documents for fatal signals.
    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = onTerm },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var model = Model.init();
    model.size = ui.size();
    model.setStatus("welcome — press q to quit", .{});
    render(&model, ui.screen());

    // Drain short input bursts before rendering. This keeps key repeat from
    // producing one full model render per queued event. The limit prevents a
    // continuous producer (for example, a large paste) from starving output.
    const max_events_per_frame = 64;
    while (try ui.nextEvent()) |first| {
        var pending: ?zooi.Event = first;
        var handled: usize = 0;
        while (pending) |ev| {
            // Hidden behind the marker flag, so a user cannot reach it: the
            // PTY suite needs the example to die abnormally on demand to check
            // that the terminal still comes back.
            if (markers_enabled) switch (ev) {
                .key => |k| switch (k) {
                    .character => |ch| if (ch == '!') @panic("example panic on request"),
                    else => {},
                },
                else => {},
            };
            const effect = update(&model, .{ .terminal = ev });
            if (executeEffect(&model, effect)) |follow_up| {
                _ = update(&model, follow_up);
            }
            handled += 1;
            if (model.quit or handled == max_events_per_frame) break;
            pending = try ui.pollEvent();
        }
        if (model.quit) break;
        render(&model, ui.screen());
    }
}
