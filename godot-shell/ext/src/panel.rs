//! The panel and the app scale: the compositor's, and the stub's on other systems.

/// The panel, the one output: 12.3 inches at 8:3.
pub const PANEL_PX: (i32, i32) = (1920, 720);
pub const PANEL_MM: (i32, i32) = (293, 110);
/// The scales offered to apps, as the 120ths wp_fractional_scale counts in divide evenly.
pub const SCALE_STEP: f64 = 0.25;
pub const SCALE_RANGE: (f64, f64) = (1.0, 2.0);

/// The app scale at which a logical pixel looks as big as CSS's reference pixel (1/96 inch at
/// 28 inches: 0.0213 degrees) from `view_mm` away, to the nearest step:
/// `px_per_mm * 25.4 / 96 * view_mm / 711.2`. The panel from 750 mm: 1.83, so 1.75.
pub fn default_scale(view_mm: f64) -> f64 {
    let px_per_mm = PANEL_PX.0 as f64 / PANEL_MM.0 as f64;
    let s = px_per_mm * 25.4 / 96.0 * view_mm / 711.2;
    ((s / SCALE_STEP).round() * SCALE_STEP).clamp(SCALE_RANGE.0, SCALE_RANGE.1)
}
