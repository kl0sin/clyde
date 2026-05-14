import SwiftUI

// MARK: - Spacing

/// Canonical spacing scale. Stick to these instead of inlining 5, 7, 11, 14…
/// in views — visual rhythm depends on a small palette.
enum Spacing {
    /// 4 pt — within a single label/pill (icon-to-text).
    static let xxs: CGFloat = 4
    /// 8 pt — between tightly related elements in one row.
    static let xs: CGFloat = 8
    /// 12 pt — default row-internal padding, related controls.
    static let sm: CGFloat = 12
    /// 16 pt — section padding, header padding.
    static let md: CGFloat = 16
    /// 20 pt — outer panel padding.
    static let lg: CGFloat = 20
}

// MARK: - Radius

/// Three corner radii, period. Previously we mixed 4 / 6 / 8 / 10 / 12.
enum Radius {
    /// 6 pt — inline pills, small buttons.
    static let small: CGFloat = 6
    /// 8 pt — rows, cards, generic surfaces.
    static let medium: CGFloat = 8
    /// 12 pt — large hero tiles (header mascot, widget face).
    static let large: CGFloat = 12
}

// MARK: - Text colours

/// Always-dark UI: text colours map to fixed white-on-black ramps.
/// Values are tuned so secondary text clears WCAG AA on Clyde's
/// `panelBackground` (≈ #1a1a1a). Use these instead of inlining
/// `Color(white: 0.35)` etc.
enum TextColor {
    /// Pure white — primary content.
    static let primary = Color.white
    /// `white: 0.75` — meaningful secondary copy (descriptions, kbd hints).
    static let secondary = Color(white: 0.75)
    /// `white: 0.55` — supporting / muted tertiary (timestamps,
    /// "no active sessions"). Floor for legibility.
    static let tertiary = Color(white: 0.55)
    /// `white: 0.55` with reduced opacity — disabled affordances.
    /// Pair with `.opacity(0.5)` on the surrounding container so the
    /// shape *and* text both read as disabled.
    static let disabled = Color(white: 0.55)
}
