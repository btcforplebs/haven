import XCTest
@testable import MediaLogic

final class NVFeedLayoutTests: XCTestCase {

    /// The promise of the whole function: rows plus the gaps between them never
    /// exceed the box, so the last row is never clipped.
    func testPlannedRowsAlwaysFitTheBox() {
        for height in stride(from: 60.0, through: 700.0, by: 7.0) {
            let plan = NVFeedLayout.plan(availableHeight: height, headerHeight: 22,
                                         rowHeight: 34, minSpacing: 6, maxSpacing: 18,
                                         noteCount: 10)
            guard plan.rows > 1 else { continue }
            let used = CGFloat(plan.rows) * 34 + CGFloat(plan.rows - 1) * plan.spacing
            XCTAssertLessThanOrEqual(used, height - 22 + 0.001,
                                     "rows overflow the widget at height \(height)")
        }
    }

    /// The other half: a taller widget must actually use the height it was
    /// given, rather than drawing three rows and leaving a hole.
    func testTallerWidgetDrawsMoreRows() {
        let medium = NVFeedLayout.plan(availableHeight: 130, headerHeight: 22, rowHeight: 34,
                                       minSpacing: 6, maxSpacing: 18, noteCount: 20)
        let large = NVFeedLayout.plan(availableHeight: 330, headerHeight: 22, rowHeight: 34,
                                      minSpacing: 6, maxSpacing: 18, noteCount: 20)
        XCTAssertGreaterThan(large.rows, medium.rows)
    }

    /// Fewer notes than fit: spread them, but only up to maxSpacing. Without the
    /// cap, two notes in a large widget end up half a widget apart.
    func testSpacingIsSpreadButCapped() {
        let plan = NVFeedLayout.plan(availableHeight: 330, headerHeight: 22, rowHeight: 34,
                                     minSpacing: 6, maxSpacing: 18, noteCount: 3)
        XCTAssertEqual(plan.rows, 3)
        XCTAssertEqual(plan.spacing, 18)
    }

    /// A packed widget falls back to the minimum gap rather than negative space.
    func testSpacingNeverGoesBelowMinimum() {
        let plan = NVFeedLayout.plan(availableHeight: 130, headerHeight: 22, rowHeight: 34,
                                     minSpacing: 6, maxSpacing: 18, noteCount: 20)
        XCTAssertGreaterThanOrEqual(plan.spacing, 6)
    }

    /// Never draw more rows than there are notes — a phantom row reads as a
    /// loading failure.
    func testRowsNeverExceedTheNotesAvailable() {
        let plan = NVFeedLayout.plan(availableHeight: 700, headerHeight: 22, rowHeight: 34,
                                     minSpacing: 6, maxSpacing: 18, noteCount: 2)
        XCTAssertEqual(plan.rows, 2)
    }

    func testNoNotesPlansNoRows() {
        let plan = NVFeedLayout.plan(availableHeight: 330, headerHeight: 22, rowHeight: 34,
                                     minSpacing: 6, maxSpacing: 18, noteCount: 0)
        XCTAssertEqual(plan.rows, 0)
    }

    /// A widget shorter than one row still draws one — something beats nothing,
    /// and SwiftUI will scale the row rather than render an empty box.
    func testTinyWidgetStillDrawsOneRow() {
        let plan = NVFeedLayout.plan(availableHeight: 30, headerHeight: 22, rowHeight: 34,
                                     minSpacing: 6, maxSpacing: 18, noteCount: 5)
        XCTAssertEqual(plan.rows, 1)
    }
}

final class NVThumbnailBudgetTests: XCTestCase {

    func testTakesNewestFirstUntilTheBudgetIsSpent() {
        let items = [("a", 40), ("b", 40), ("c", 40)]
        XCTAssertEqual(NVThumbnailBudget.fit(items, budget: 100), ["a", "b"])
    }

    /// One oversized blob must not cost every thumbnail behind it.
    func testOversizedItemIsSkippedNotFatal() {
        let items = [("huge", 5_000), ("a", 40), ("b", 40)]
        XCTAssertEqual(NVThumbnailBudget.fit(items, budget: 100), ["a", "b"])
    }

    func testEmptyBudgetKeepsNothing() {
        XCTAssertTrue(NVThumbnailBudget.fit([("a", 10)], budget: 0).isEmpty)
    }

    /// A zero-byte encode is a failed encode, not a free tile.
    func testZeroByteItemsAreDropped() {
        XCTAssertEqual(NVThumbnailBudget.fit([("empty", 0), ("a", 10)], budget: 100), ["a"])
    }

    func testExactFitIsKept() {
        XCTAssertEqual(NVThumbnailBudget.fit([("a", 100)], budget: 100), ["a"])
    }
}

final class NVMediaFilterTests: XCTestCase {

    func testAllAcceptsEveryKind() {
        for kind in [NVMediaKind.image, .video, .gif, .other] {
            XCTAssertTrue(NVMediaFilter.all.accepts(kind))
        }
    }

    func testNarrowChipsAcceptOnlyTheirOwnKind() {
        XCTAssertTrue(NVMediaFilter.photo.accepts(.image))
        XCTAssertFalse(NVMediaFilter.photo.accepts(.video))
        XCTAssertFalse(NVMediaFilter.photo.accepts(.gif))
        XCTAssertTrue(NVMediaFilter.video.accepts(.video))
        XCTAssertTrue(NVMediaFilter.gif.accepts(.gif))
    }

    /// A GIF is an image on disk. If `photo` accepted it, the Photos chip and
    /// the GIF chip would show the same tiles and the filter would look broken.
    func testGifIsNotAPhoto() {
        XCTAssertFalse(NVMediaFilter.photo.accepts(.gif))
    }

    /// Tiles written by an older build carry no kind. Show them under All,
    /// hide them everywhere else rather than guessing.
    func testUnknownKindOnlyAppearsUnderAll() {
        XCTAssertTrue(NVMediaFilter.all.accepts(nil))
        XCTAssertFalse(NVMediaFilter.photo.accepts(nil))
        XCTAssertFalse(NVMediaFilter.video.accepts(nil))
        XCTAssertFalse(NVMediaFilter.gif.accepts(nil))
    }
}
