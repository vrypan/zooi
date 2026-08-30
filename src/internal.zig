//! The internals, gathered for the runtime verifier.
//!
//! `zooi.zig` is the API; this is not part of it. The verifier checks that the
//! syscalls underneath work on a given machine, which is exactly what the
//! public surface exists to hide, so it needs a way in. One entry point rather
//! than a module per file because Zig gives each file to exactly one module,
//! and `terminal.zig` already imports `sys.zig`.
//!
//! Nothing else should import this. If a consumer needs something here, that
//! is a case for exporting it from `zooi.zig` deliberately.

pub const sys = @import("sys.zig");
pub const terminal = @import("terminal.zig");
pub const input = @import("input.zig");
pub const screen = @import("screen.zig");
pub const event = @import("event.zig");
pub const width = @import("width.zig");
