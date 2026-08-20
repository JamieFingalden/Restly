import XCTest
@testable import Restly

final class HealthToastQueueTests: XCTestCase {
    func testQueueKeepsFIFOOrderAndDeduplicatesPendingTypes() {
        let water = HealthToast(type: .water, intervalMinutes: 45)
        let stand = HealthToast(type: .stand, intervalMinutes: 50)
        let duplicateWater = HealthToast(type: .water, intervalMinutes: 60)
        var queue = HealthToastQueue()

        XCTAssertTrue(queue.enqueue(water))
        XCTAssertTrue(queue.enqueue(stand))
        XCTAssertFalse(queue.enqueue(duplicateWater))
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.dequeue(), water)
        XCTAssertEqual(queue.dequeue(), stand)
        XCTAssertTrue(queue.isEmpty)
    }

    func testLayoutCentersToastAndKeepsTopSafeArea() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_800, height: 1_169)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_800, height: 1_131)
        let toastSize = CGSize(width: 324, height: 68)
        let frame = HealthToastLayout.frame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            toastSize: toastSize,
            topSafeArea: 20
        )

        XCTAssertEqual(frame.midX, screenFrame.midX)
        XCTAssertEqual(visibleFrame.maxY - frame.maxY, 20)
    }
}
