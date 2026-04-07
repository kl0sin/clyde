import SwiftUI

// MARK: - Colors & Labels (single source of truth)

enum SessionTheme {
    /// Matches the widget's dominant-block palette. Purple for "working"
    /// signals AI processing; blue for attention; green for ready.
    static let processingColor = Color(red: 0.749, green: 0.353, blue: 0.949) // #bf5af2
    static let attentionColor = Color.blue
    static let readyColor = Color.green
    static let processingLabel = "Working"
    static let attentionLabel = "Needs input"
    static let readyLabel = "Ready"

    static func color(for status: SessionStatus) -> Color {
        status == .busy ? processingColor : readyColor
    }

    static func label(for status: SessionStatus) -> String {
        status == .busy ? processingLabel : readyLabel
    }
}
