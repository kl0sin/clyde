import SwiftUI

// MARK: - Colors & Labels (single source of truth)

enum SessionTheme {
    static let processingColor = Color.orange
    static let readyColor = Color.green
    static let processingLabel = "Processing"
    static let readyLabel = "Ready"

    static func color(for status: SessionStatus) -> Color {
        status == .busy ? processingColor : readyColor
    }

    static func label(for status: SessionStatus) -> String {
        status == .busy ? processingLabel : readyLabel
    }
}
