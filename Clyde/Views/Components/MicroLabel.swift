import SwiftUI

/// Uppercase, letter-spaced, in the state's colour. A label rather than
/// a sentence: the row has room for rhythm, not prose.
struct MicroLabel: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(color.opacity(0.9))
    }
}

