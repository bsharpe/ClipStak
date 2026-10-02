import XCTest
@testable import ClipStakCore

final class SheetNavigationTests: XCTestCase {
    // A 5-column sheet of 12 clips:
    //  0  1  2  3  4
    //  5  6  7  8  9
    // 10 11
    private func move(_ direction: SheetNavigation.Direction, from index: Int) -> Int {
        SheetNavigation.move(direction, from: index, columns: 5, count: 12)
    }

    func testLeftAndRightReadAcrossRowEndsLikeText() {
        XCTAssertEqual(move(.right, from: 4), 5)
        XCTAssertEqual(move(.left, from: 5), 4)
    }

    func testLeftAndRightStopAtTheNewestAndOldestClips() {
        // Wrapping from the newest clip to the oldest would jump the selection off screen.
        XCTAssertEqual(move(.left, from: 0), 0)
        XCTAssertEqual(move(.right, from: 11), 11)
    }

    func testUpAndDownKeepTheColumn() {
        XCTAssertEqual(move(.down, from: 1), 6)
        XCTAssertEqual(move(.up, from: 6), 1)
    }

    func testUpOnTheFirstRowStaysPut() {
        XCTAssertEqual(move(.up, from: 3), 3)
    }

    func testDownIntoAShortLastRowLandsOnTheOldestClip() {
        // Nothing sits below 8, so staying put would leave 10 and 11 unreachable with the down arrow.
        XCTAssertEqual(move(.down, from: 8), 11)
        XCTAssertEqual(move(.down, from: 6), 11)
        XCTAssertEqual(move(.down, from: 5), 10)
    }

    func testDownOnTheLastRowStaysPut() {
        XCTAssertEqual(move(.down, from: 10), 10)
        XCTAssertEqual(move(.down, from: 11), 11)
    }

    func testAnEmptySheetHasNothingToSelect() {
        XCTAssertEqual(SheetNavigation.move(.down, from: 0, columns: 5, count: 0), 0)
        XCTAssertEqual(SheetNavigation.move(.right, from: 0, columns: 5, count: 0), 0)
    }
}
