import XCTest
@testable import Clyde

/// Whether to offer moving Clyde into Applications, and where to put it.
///
/// macOS keeps a separate permission for every copy of an app, so a
/// second copy is a second row in System Settings — and one opened
/// straight from a download is translocated to a random read-only path,
/// where a granted permission belongs to a directory that is about to
/// disappear. Every app that needs a permission solves this the same
/// way: offer to move itself, once, at first launch.
final class MoveToApplicationsTests: XCTestCase {

    func testAnInstalledCopyIsNeverAsked() {
        XCTAssertFalse(MoveToApplications.shouldOffer(location: .installed,
                                                      isDevBuild: false,
                                                      declinedBefore: false))
    }

    /// Only where the copy is doomed: a translocated copy lives in a
    /// directory macOS is about to throw away, and one on a disk image
    /// disappears on eject. A permission granted from either is lost
    /// the moment it is given.
    func testADoomedCopyIsOffered() {
        for location: AppLocation in [.translocated, .diskImage] {
            XCTAssertTrue(MoveToApplications.shouldOffer(location: location,
                                                         isDevBuild: false,
                                                         declinedBefore: false),
                          "\(location) should be offered")
        }
    }

    /// A copy sitting in Downloads works perfectly well until someone
    /// moves it, so it gets the panel's advisory rather than a modal in
    /// front of a menu-bar app that has not even drawn its icon yet.
    func testAnOrdinaryStrayCopyIsLeftToTheAdvisory() {
        XCTAssertFalse(MoveToApplications.shouldOffer(location: .elsewhere,
                                                      isDevBuild: false,
                                                      declinedBefore: false))
    }

    /// Asked once. An app that asks the same question at every launch
    /// teaches people to dismiss it without reading.
    func testDecliningIsRemembered() {
        XCTAssertFalse(MoveToApplications.shouldOffer(location: .diskImage,
                                                      isDevBuild: false,
                                                      declinedBefore: true))
    }

    /// A development build lives in a build directory on purpose, and
    /// moving it into Applications would replace the copy under test.
    func testADevelopmentBuildIsLeftWhereItIs() {
        XCTAssertFalse(MoveToApplications.shouldOffer(location: .diskImage,
                                                      isDevBuild: true,
                                                      declinedBefore: false))
    }

    // MARK: - Where it goes

    func testTheDestinationKeepsTheBundleName() {
        XCTAssertEqual(MoveToApplications.destination(for: "/Users/me/Downloads/Clyde.app").path,
                       "/Applications/Clyde.app")
    }

    /// A translocated copy cannot be moved: the path is a read-only
    /// mirror macOS made. The original is what has to travel, and if we
    /// cannot find it there is nothing honest to do but say so.
    func testATranslocatedCopyNeedsItsOriginal() {
        XCTAssertTrue(MoveToApplications.needsOriginalPath(for: .translocated))
        XCTAssertFalse(MoveToApplications.needsOriginalPath(for: .elsewhere))
    }

    // MARK: - The move itself

    private func makeBundle(named name: String, in dir: URL, marker: String) throws -> URL {
        let bundle = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try marker.write(to: bundle.appendingPathComponent("Contents/MacOS/Clyde"),
                         atomically: true, encoding: .utf8)
        return bundle
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clyde-move-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testTheCopyArrivesAndTheStrayOneGoes() throws {
        let downloads = tempDir(), applications = tempDir()
        let source = try makeBundle(named: "Clyde.app", in: downloads, marker: "new")

        let moved = try MoveToApplications.move(from: source, into: applications)

        XCTAssertEqual(moved.standardizedFileURL.path,
                       applications.appendingPathComponent("Clyde.app").standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "the stray copy is the whole problem — leaving it brings the second row back")
    }

    /// An older copy already in Applications is replaced, not deleted
    /// first: an interrupted delete would leave the user with none.
    func testAnOlderCopyIsReplaced() throws {
        let downloads = tempDir(), applications = tempDir()
        _ = try makeBundle(named: "Clyde.app", in: applications, marker: "old")
        let source = try makeBundle(named: "Clyde.app", in: downloads, marker: "new")

        let moved = try MoveToApplications.move(from: source, into: applications)

        let landed = try String(contentsOf: moved.appendingPathComponent("Contents/MacOS/Clyde"),
                                encoding: .utf8)
        XCTAssertEqual(landed, "new")
    }

    /// Nothing is deleted from a disk image — it is read-only, and the
    /// copy there disappears on eject anyway.
    func testADiskImageIsLeftAlone() {
        XCTAssertFalse(MoveToApplications.shouldRemoveSource(at: .diskImage))
        XCTAssertTrue(MoveToApplications.shouldRemoveSource(at: .elsewhere))
        XCTAssertTrue(MoveToApplications.shouldRemoveSource(at: .translocated))
    }
}
