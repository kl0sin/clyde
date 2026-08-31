import XCTest
import AppKit
@testable import Clyde

/// ⌃⌘C is the advertised way to open Clyde from anywhere. Reported dead
/// on two machines.
///
/// The matcher compared the event's modifier flags for exact equality
/// against [.control, .command] and read the letter from
/// `charactersIgnoringModifiers`. Both are fragile in ways that produce
/// exactly "nothing happens, ever":
///
///  - `deviceIndependentFlagsMask` includes Caps Lock, so with Caps Lock
///    on the flags are [.control, .command, .capsLock] and the equality
///    fails. Same for the `.function` flag some keyboards set.
///  - With Control held, `charactersIgnoringModifiers` can arrive as the
///    control character U+0003 rather than "c", depending on keyboard
///    and layout — which is the case that matches a shortcut that works
///    for nobody.
///
/// The physical key is the reliable signal: keyCode 8 is C on every
/// layout that has one.
final class HotKeyMatchingTests: XCTestCase {

    private func keyEvent(flags: NSEvent.ModifierFlags,
                          characters: String,
                          keyCode: UInt16 = 8) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: flags,
                         timestamp: 0,
                         windowNumber: 0,
                         context: nil,
                         characters: characters,
                         charactersIgnoringModifiers: characters,
                         isARepeat: false,
                         keyCode: keyCode)!
    }

    func testTheAdvertisedShortcutMatches() {
        XCTAssertTrue(AppDelegate.isToggleShortcut(
            keyEvent(flags: [.control, .command], characters: "c")))
    }

    /// The control character case: Control held, and the event carries
    /// U+0003 instead of "c".
    func testItMatchesWhenTheEventCarriesTheControlCharacter() {
        XCTAssertTrue(AppDelegate.isToggleShortcut(
            keyEvent(flags: [.control, .command], characters: "\u{03}")))
    }

    /// Caps Lock is part of deviceIndependentFlagsMask. A shortcut that
    /// stops working because Caps Lock is on is a shortcut that looks
    /// broken at random.
    func testCapsLockDoesNotBreakIt() {
        XCTAssertTrue(AppDelegate.isToggleShortcut(
            keyEvent(flags: [.control, .command, .capsLock], characters: "c")))
    }

    func testTheFunctionFlagDoesNotBreakIt() {
        XCTAssertTrue(AppDelegate.isToggleShortcut(
            keyEvent(flags: [.control, .command, .function], characters: "c")))
    }

    // MARK: - What must still not match

    func testAnotherKeyDoesNotMatch() {
        XCTAssertFalse(AppDelegate.isToggleShortcut(
            keyEvent(flags: [.control, .command], characters: "v", keyCode: 9)))
    }

    func testPlainCopyDoesNotMatch() {
        XCTAssertFalse(AppDelegate.isToggleShortcut(
            keyEvent(flags: [.command], characters: "c")))
    }

    func testControlAloneDoesNotMatch() {
        XCTAssertFalse(AppDelegate.isToggleShortcut(
            keyEvent(flags: [.control], characters: "c")))
    }

    /// Adding a modifier makes it a different shortcut, and one the user
    /// may have bound elsewhere.
    func testExtraModifiersDoNotMatch() {
        XCTAssertFalse(AppDelegate.isToggleShortcut(
            keyEvent(flags: [.control, .command, .shift], characters: "c")))
        XCTAssertFalse(AppDelegate.isToggleShortcut(
            keyEvent(flags: [.control, .command, .option], characters: "c")))
    }
}
