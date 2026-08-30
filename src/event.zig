//! Events delivered by the loop, and the terminal dimensions they carry.
//!
//! `Event` and `Ui` join `Size` here when the event source lands.

/// Terminal dimensions.
///
/// Either field may legitimately be `0`: a pty with no size set reports
/// `0 x 0`, which was observed on real hardware and is not an error. Callers
/// clip rather than assume a minimum.
pub const Size = struct {
    rows: u16,
    cols: u16,
};
