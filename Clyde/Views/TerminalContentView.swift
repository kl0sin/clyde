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
        scrollView.drawsBackground = false

        let textView = TerminalTextView()
        textView.isEditable = true // Must be true for keyDown to work
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        textView.insertionPointColor = .white
        textView.textColor = .white
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byCharWrapping

        textView.terminalSession = session

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TerminalTextView else { return }

        let stripped = stripANSI(session.outputText)

        if textView.lastRenderedLength != stripped.count {
            let wasAtBottom = isScrolledToBottom(scrollView)
            textView.terminalSession = nil // Prevent feedback loop
            textView.string = stripped
            textView.lastRenderedLength = stripped.count
            textView.terminalSession = session

            // Move cursor to end
            textView.setSelectedRange(NSRange(location: stripped.count, length: 0))

            if wasAtBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }

        textView.terminalSession = session

        // Ensure focus
        if textView.window != nil && textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        let visibleRect = scrollView.contentView.bounds
        let documentHeight = documentView.frame.height
        return visibleRect.maxY >= documentHeight - 30
    }

    private func stripANSI(_ text: String) -> String {
        let pattern = "\\x1b\\[[0-9;?]*[A-Za-z]|\\x1b\\][^\u{07}\\x1b]*(?:\u{07}|\\x1b\\\\)|\\x1b[()][A-Z0-9]|\\x1b[>=<]|\\r"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }
}

/// NSTextView that intercepts all typing and sends it to the PTY instead
final class TerminalTextView: NSTextView {
    var terminalSession: TerminalSession?
    var lastRenderedLength: Int = 0

    override var acceptsFirstResponder: Bool { true }

    // Intercept ALL text input — send to PTY, don't modify text view
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = string as? String else { return }
        terminalSession?.sendInput(text)
    }

    override func doCommand(by selector: Selector) {
        // Handle common commands
        switch selector {
        case #selector(insertNewline(_:)):
            terminalSession?.sendInput("\r")
        case #selector(deleteBackward(_:)):
            terminalSession?.sendKey(0x7F)
        case #selector(insertTab(_:)):
            terminalSession?.sendInput("\t")
        case #selector(cancelOperation(_:)):
            terminalSession?.sendInput("\u{1b}")
        case #selector(moveUp(_:)):
            terminalSession?.sendInput("\u{1b}[A")
        case #selector(moveDown(_:)):
            terminalSession?.sendInput("\u{1b}[B")
        case #selector(moveRight(_:)):
            terminalSession?.sendInput("\u{1b}[C")
        case #selector(moveLeft(_:)):
            terminalSession?.sendInput("\u{1b}[D")
        default:
            break // Ignore other commands
        }
    }

    override func keyDown(with event: NSEvent) {
        // Handle Ctrl+key combinations
        if event.modifierFlags.contains(.control), let chars = event.characters,
           let char = chars.unicodeScalars.first {
            let controlCode = char.value & 0x1F
            if controlCode < 32 {
                terminalSession?.sendKey(UInt8(controlCode))
                return
            }
        }

        // Let the input method system handle it (calls insertText or doCommand)
        interpretKeyEvents([event])
    }

    // Click to focus
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    // Don't allow pasting into the text view directly — send to PTY
    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            terminalSession?.sendInput(text)
        }
    }
}
