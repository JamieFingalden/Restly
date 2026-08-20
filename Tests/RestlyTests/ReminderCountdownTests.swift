import XCTest
@testable import Restly

final class ReminderCountdownTests: XCTestCase {
    func testCountdownOnlyAdvancesDuringActiveUseAndCanReset() {
        var countdown = ReminderCountdown(duration: 30)

        XCTAssertFalse(countdown.advance(by: 20, whileActive: false))
        XCTAssertEqual(countdown.remaining, 30)
        XCTAssertFalse(countdown.advance(by: 10, whileActive: true))
        XCTAssertEqual(countdown.remaining, 20)
        XCTAssertTrue(countdown.advance(by: 20, whileActive: true))
        XCTAssertEqual(countdown.remaining, 0)

        countdown.reset(to: 45)
        XCTAssertEqual(countdown.remaining, 45)
    }

    func testActivityClassificationUsesIdleAndAwayThresholds() {
        XCTAssertEqual(
            ActivityMonitor.classify(idleSeconds: 20, idleThreshold: 180, awayThreshold: 480),
            .active
        )
        XCTAssertEqual(
            ActivityMonitor.classify(idleSeconds: 240, idleThreshold: 180, awayThreshold: 480),
            .idle
        )
        XCTAssertEqual(
            ActivityMonitor.classify(idleSeconds: 600, idleThreshold: 180, awayThreshold: 480),
            .away
        )
    }

    @MainActor
    func testEyeRestProgressUsesContinuousElapsedTime() {
        let startDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let session = EyeRestSession(durationSeconds: 20) { _ in }
        session.start(at: startDate)
        defer { session.cancel() }

        XCTAssertEqual(session.progress(at: startDate.addingTimeInterval(2.5)), 0.875)
        XCTAssertEqual(session.progress(at: startDate.addingTimeInterval(20)), 0)
    }
}
