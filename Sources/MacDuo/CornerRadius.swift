import CoreGraphics

/// Apple-standard corner radii (points) shared across the app's interface, so
/// the overlay, cards, notices, and controls speak one consistent rounded
/// language.
///
/// The values follow macOS conventions rather than being measured per device.
/// That keeps the look uniform everywhere and avoids fragile, device-specific
/// probing (e.g. private `CGSGetDisplayCornerRadius` lookups) — the system
/// already rounds popovers, buttons, and standard controls, and the remaining
/// custom elements simply adopt these reference values.
enum CornerRadius {
    /// Inline notices and small callouts.
    static let notice: CGFloat = 10
    /// Grouped setting cards and panels.
    static let card: CGFloat = 12
    /// Buttons and compact controls. The system already rounds these; this is
    /// the reference value for any custom control we draw.
    static let control: CGFloat = 6
    /// The radius the folded picture's own corners are rounded to, in points.
    ///
    /// The cover edge also uses it, but the visible effect is on the picture:
    /// as the lid closes the captured screen turns away, and a sharp rectangle
    /// reads as a square card instead of a screen. Rounding the picture's
    /// corners gives it the device-screen look. A fixed reference value rather
    /// than a measured one: the private `CGSGetDisplayCornerRadius` lookup is
    /// unavailable on current macOS, so this approximates the MacBook display
    /// corner (the 14"/16" MacBook Pro display has rounded corners).
    static let display: CGFloat = 20
}
