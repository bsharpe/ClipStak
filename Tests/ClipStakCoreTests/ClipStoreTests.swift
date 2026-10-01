import XCTest
@testable import ClipStakCore

final class ClipStoreTests: XCTestCase {
    func testANewCopyBecomesTheClipYouSeeFirst() {
        var store = ClipStore()
        XCTAssertEqual(store.record(text: "first", appName: "iTerm2", bundlePath: nil, at: date(1)), .recorded)
        XCTAssertEqual(store.record(text: "second", appName: "Code", bundlePath: nil, at: date(2)), .recorded)
        XCTAssertEqual(store.current?.text, "second")
        XCTAssertEqual(store.positionLabel, "1 of 2")
    }

    func testCopyingTheSameTextAgainDoesNotGrowHistory() {
        // The pasteboard poll will see our own paste. That must not push a duplicate
        // and must not shove the user off the clip they were browsing.
        var store = ClipStore()
        store.record(text: "older", appName: "Code", bundlePath: nil, at: date(1))
        store.record(text: "same", appName: "Code", bundlePath: nil, at: date(2))
        XCTAssertTrue(store.older())
        XCTAssertEqual(store.record(text: "same", appName: "Code", bundlePath: nil, at: date(3)), .ignored)
        XCTAssertEqual(store.clips.map(\.text), ["same", "older"])
        XCTAssertEqual(store.index, 1)
    }

    func testCopyingAnOlderClipBringsItBackToTheFront() {
        var store = ClipStore()
        store.record(text: "old", appName: "Code", bundlePath: nil, at: date(1))
        store.record(text: "new", appName: "Code", bundlePath: nil, at: date(2))
        XCTAssertEqual(store.record(text: "old", appName: "iTerm2", bundlePath: nil, at: date(3)), .recorded)
        XCTAssertEqual(store.clips.map(\.text), ["old", "new"])
        XCTAssertEqual(store.current?.appName, "iTerm2")
        XCTAssertEqual(store.index, 0)
    }

    func testHistoryKeepsTheNewestFortyAndDropsTheOldest() {
        var store = ClipStore()
        for n in 0..<45 {
            store.record(text: "clip \(n)", appName: "Code", bundlePath: nil, at: date(n))
        }
        XCTAssertEqual(store.clips.count, 40)
        XCTAssertEqual(store.clips.first?.text, "clip 44")
        XCTAssertEqual(store.clips.last?.text, "clip 5")
        XCTAssertFalse(store.clips.contains { $0.text == "clip 4" })
    }

    func testEmptyAndHugeCopiesAreIgnoredSoTheMenuDoesNotDie() {
        var store = ClipStore()
        XCTAssertEqual(store.record(text: "", appName: "", bundlePath: nil, at: date(1)), .ignored)
        let huge = String(repeating: "x", count: ClipStore.maxClipLength + 1)
        XCTAssertEqual(store.record(text: huge, appName: "Code", bundlePath: nil, at: date(1)), .ignored)
        XCTAssertTrue(store.clips.isEmpty)
    }

    func testHoldingTheHotkeyWalksBackwardAndStopsOnTheOldest() {
        var store = ClipStore()
        store.record(text: "a", appName: "", bundlePath: nil, at: date(1))
        store.record(text: "b", appName: "", bundlePath: nil, at: date(2))
        store.record(text: "c", appName: "", bundlePath: nil, at: date(3))
        XCTAssertTrue(store.older())
        XCTAssertEqual(store.current?.text, "b")
        XCTAssertTrue(store.older())
        XCTAssertEqual(store.current?.text, "a")
        XCTAssertFalse(store.older())
        XCTAssertEqual(store.current?.text, "a")
        XCTAssertTrue(store.newer())
        XCTAssertEqual(store.current?.text, "b")
    }

    func testNumberKeysJumpAndZeroMeansTheTenthClip() {
        var store = ClipStore()
        for n in 1...12 {
            store.record(text: "\(n)", appName: "", bundlePath: nil, at: date(n))
        }
        // Newest is "12" at index 0. Key 3 is the third clip, "10".
        store.jumpToNumberKey(3)
        XCTAssertEqual(store.current?.text, "10")
        store.jumpToNumberKey(0)
        XCTAssertEqual(store.current?.text, "3")
    }

    func testEscapeLeavesThePositionForTheNextGesture() {
        var store = ClipStore()
        store.record(text: "a", appName: "", bundlePath: nil, at: date(1))
        store.record(text: "b", appName: "", bundlePath: nil, at: date(2))
        store.older()
        XCTAssertEqual(store.index, 1)
        XCTAssertEqual(store.current?.text, "a")
    }

    func testDeleteRemovesTheClipOnScreen() {
        var store = ClipStore()
        store.record(text: "a", appName: "", bundlePath: nil, at: date(1))
        store.record(text: "b", appName: "", bundlePath: nil, at: date(2))
        store.older()
        XCTAssertTrue(store.deleteCurrent())
        XCTAssertEqual(store.clips.map(\.text), ["b"])
        XCTAssertEqual(store.current?.text, "b")
    }

    func testMenuShowsTenShortSingleLineTitles() {
        var store = ClipStore()
        for n in 0..<12 {
            store.record(text: "line \(n)\nmore", appName: "", bundlePath: nil, at: date(n))
        }
        let items = store.menuItems()
        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(items[0].title, "line 11 more")
        XCTAssertEqual(items[0].index, 0)
        let long = String(repeating: "ab", count: 30)
        XCTAssertEqual(ClipStore.menuTitle(long).count, 40)
        XCTAssertTrue(ClipStore.menuTitle(long).hasSuffix("…"))
    }

    func testSaveAndLoadRoundTripKeepsOrderAndThePauseFlag() throws {
        var store = ClipStore()
        store.record(text: "alpha", appName: "Code", bundlePath: "/Applications/Visual Studio Code.app", at: date(10))
        store.paused = true
        store.sticky = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipstak-test-\(UUID().uuidString).json")
        try store.save(to: url)
        let loaded = try ClipStore.load(from: url)
        XCTAssertEqual(loaded, store)
        XCTAssertEqual(HistoryPersistence(url: url).load(), store)
        try FileManager.default.removeItem(at: url)
    }

    func testConcealedAndTransientClipboardEntriesAreNotCaptured() {
        XCTAssertFalse(ClipboardPolicy.shouldCapture(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertFalse(ClipboardPolicy.shouldCapture(types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"]))
        XCTAssertTrue(ClipboardPolicy.shouldCapture(types: ["public.utf8-plain-text"]))
    }

    func testUnreadableHistoryIsPreservedBeforeAReplacementIsSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipstak-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let original = Data("not valid JSON".utf8)
        try original.write(to: url)

        let persistence = HistoryPersistence(url: url)
        XCTAssertTrue(persistence.load().clips.isEmpty)
        let backupURL = try XCTUnwrap(persistence.backupURL)
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        var store = ClipStore()
        XCTAssertEqual(store.record(text: "new clip", appName: "", bundlePath: nil, at: date(1)), .recorded)
        XCTAssertTrue(persistence.save(store))
        XCTAssertEqual(try ClipStore.load(from: url).clips.map(\.text), ["new clip"])
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
    }

    func testFailedHistorySaveIsReportedAndCanBeRetried() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipstak-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("blocked")
        try Data().write(to: parent)
        let persistence = HistoryPersistence(url: parent.appendingPathComponent("history.json"))
        var store = ClipStore()
        XCTAssertEqual(store.record(text: "keep me", appName: "", bundlePath: nil, at: date(1)), .recorded)

        XCTAssertFalse(persistence.save(store))
        XCTAssertNotNil(persistence.lastError)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertTrue(persistence.save(store))
        XCTAssertNil(persistence.lastError)
        XCTAssertEqual(try ClipStore.load(from: persistence.url).clips.map(\.text), ["keep me"])
    }

    func testHistoryThatCannotBeReadIsLeftInPlaceAndBlocksSaving() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipstak-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let persistence = HistoryPersistence(url: url)
        XCTAssertTrue(persistence.load().clips.isEmpty)
        XCTAssertFalse(persistence.canSave)
        XCTAssertNotNil(persistence.lastError)
        XCTAssertNil(persistence.backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(persistence.save(ClipStore()))
    }

    func testPendingPasteRequiresTheSameAppAndClipboardContents() {
        XCTAssertTrue(ClipboardPolicy.canCompletePaste(expectedChangeCount: 4, currentChangeCount: 4, targetPID: 100, frontmostPID: 100))
        XCTAssertFalse(ClipboardPolicy.canCompletePaste(expectedChangeCount: 4, currentChangeCount: 5, targetPID: 100, frontmostPID: 100))
        XCTAssertFalse(ClipboardPolicy.canCompletePaste(expectedChangeCount: 4, currentChangeCount: 4, targetPID: 100, frontmostPID: 101))
        XCTAssertFalse(ClipboardPolicy.canCompletePaste(expectedChangeCount: 4, currentChangeCount: 4, targetPID: nil, frontmostPID: nil))
    }

    func testFlycutHistoryImportsNewestFirstAndSkipsNonText() {
        let store: [String: Any] = [
            "jcList": [
                [
                    "Contents": "newest",
                    "AppLocalizedName": "iTerm2",
                    "AppBundleURL": "/Applications/iTerm.app",
                    "Timestamp": 1_700_000_000,
                ],
                [
                    "Contents": "older",
                    "AppLocalizedName": "Code",
                    "Timestamp": 1_600_000_000,
                ],
                [
                    "AppLocalizedName": "Preview",
                    "Timestamp": 1_500_000_000,
                ],
            ]
        ]
        let clips = ClipStore.importingFlycutStore(store)
        XCTAssertEqual(clips.map(\.text), ["newest", "older"])
        XCTAssertEqual(clips[0].appName, "iTerm2")
        XCTAssertEqual(clips[0].copiedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func date(_ n: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + n))
    }
}
