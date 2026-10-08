import XCTest
@testable import Restly

final class EyeRestSessionTests: XCTestCase {
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
