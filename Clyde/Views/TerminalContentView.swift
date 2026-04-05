import SwiftUI
import AppKit

struct TerminalContentView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)

        let textView = TerminalTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        textView.textColor = .white
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byCharWrapping

        // Store session reference for keyboard input
        textView.terminalSession = session

        scrollView.documentView = textView

        // Make text view first responder for keyboard input
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = textView.window {
                // Ensure the panel is key and can receive keyboard
                window.makeKey()
                window.makeFirstResponder(textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TerminalTextView else { return }

        let stripped = stripANSI(session.outputText)

        // Only update if text changed
        if textView.string != stripped {
            let wasAtBottom = isScrolledToBottom(scrollView)
            textView.string = stripped

            // Auto-scroll to bottom if user was already at bottom
            if wasAtBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }

        // Update session reference
        textView.terminalSession = session
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        let visibleRect = scrollView.contentView.bounds
        let documentHeight = documentView.frame.height
        return visibleRect.maxY >= documentHeight - 20
    }

    /// Strip ANSI escape sequences from text
    private func stripANSI(_ text: String) -> String {
        // Match ESC[ followed by any number of params and a final letter
        // Also match ESC] (OSC sequences) terminated by BEL or ST
        let pattern = "\\x1b\\[[0-9;?]*[A-Za-z]|\\x1b\\][^\u{07}\\x1b]*(?:\u{07}|\\x1b\\\\)|\\x1b[()][A-Z0-9]|\\x1b[>=<]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }
}

/// Custom NSTextView that forwards keyboard events to the terminal session
final class TerminalTextView: NSTextView {
    var terminalSession: TerminalSession?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let session = terminalSession else { return }

        // Handle special keys
        if let specialSequence = mapSpecialKey(event) {
            session.sendInput(specialSequence)
            return
        }

        // Regular character input
        if let chars = event.characters {
            // Handle Ctrl+key combinations
            if event.modifierFlags.contains(.control), let char = chars.unicodeScalars.first {
                let controlChar = char.value - 96 // 'a' = 1, 'b' = 2, etc.
                if controlChar > 0 && controlChar < 32 {
                    session.sendKey(UInt8(controlChar))
                    return
                }
            }

            session.sendInput(chars)
        }
    }

    override func insertNewline(_ sender: Any?) {
        terminalSession?.sendInput("\r")
    }

    override func deleteBackward(_ sender: Any?) {
        terminalSession?.sendKey(0x7F) // DEL
    }

    override func insertTab(_ sender: Any?) {
        terminalSession?.sendInput("\t")
    }

    private func mapSpecialKey(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 123: return "\u{1b}[D"  // Left arrow
        case 124: return "\u{1b}[C"  // Right arrow
        case 125: return "\u{1b}[B"  // Down arrow
        case 126: return "\u{1b}[A"  // Up arrow
        case 115: return "\u{1b}[H"  // Home
        case 119: return "\u{1b}[F"  // End
        case 116: return "\u{1b}[5~" // Page Up
        case 121: return "\u{1b}[6~" // Page Down
        case 51:  return "\u{7f}"    // Backspace -> DEL
        case 53:  return "\u{1b}"    // Escape
        default:  return nil
        }
    }

    // Prevent beep on unhandled keys
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            return super.performKeyEquivalent(with: event)
        }
        return false
    }
}
