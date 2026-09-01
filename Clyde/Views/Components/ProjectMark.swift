import SwiftUI

/// A project's initial in the same stepped square a session's row uses.
///
/// The list of projects was a column of names and figures with nothing
/// to catch the eye on the way down. This is the mark that column was
/// missing, and it is the mark the rest of the app already draws — the
/// review window should not invent a second visual language for the
/// same idea.
///
/// The colour comes from the name, so a project keeps its colour across
/// periods and sessions and you learn it. It is drawn from a fixed set
/// rather than from a free hue, so nothing lands on the colours that
/// already mean something: working, waiting and needs-you.
struct ProjectMark: View {
    let name: String
    var size: CGFloat = 28

    /// Deliberately none of `SessionTheme`'s state colours. A project is
    /// not a state, and a project that happened to hash to green would
    /// read as one.
    static let palette: [Color] = [
        Color(red: 0.51, green: 0.44, blue: 0.87),
        Color(red: 0.29, green: 0.60, blue: 0.85),
        Color(red: 0.85, green: 0.53, blue: 0.35),
        Color(red: 0.78, green: 0.40, blue: 0.60),
        Color(red: 0.40, green: 0.68, blue: 0.66),
        Color(red: 0.72, green: 0.63, blue: 0.32)
    ]

    /// Stable across launches, which `hashValue` is not: Swift seeds
    /// string hashing per process, so a project would change colour
    /// every time the app started.
    static func colourIndex(for name: String) -> Int {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return sum % palette.count
    }

    static func initial(for name: String) -> String {
        let letter = name.first(where: { $0.isLetter || $0.isNumber }) ?? name.first ?? "?"
        return String(letter).uppercased()
    }

    private var colour: Color { Self.palette[Self.colourIndex(for: name)] }

    var body: some View {
        ZStack {
            SteppedSquare(step: size * SteppedSquare.stepRatio)
                .fill(colour.opacity(0.18))
            SteppedSquare(step: size * SteppedSquare.stepRatio)
                .stroke(colour.opacity(0.45), lineWidth: 1)
            Text(Self.initial(for: name))
                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                .foregroundStyle(colour)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
