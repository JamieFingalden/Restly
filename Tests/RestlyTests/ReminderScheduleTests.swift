import XCTest
@testable import Restly

final class ReminderScheduleTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 1_000)

    func testFireDateAndRemainingComeFromWallClock() {
        let schedule = ReminderSchedule(startDate: origin, interval: 1_800)

        XCTAssertEqual(schedule.fireDate, origin.addingTimeInterval(1_800))
        XCTAssertEqual(schedule.remaining(at: origin.addingTimeInterval(600)), 1_200)
        XCTAssertFalse(schedule.isDue(at: origin.addingTimeInterval(1_799)))
        XCTAssertTrue(schedule.isDue(at: origin.addingTimeInterval(1_800)))
        // 过了触发时刻之后剩余时间钳在 0，不会变成负数。
        XCTAssertEqual(schedule.remaining(at: origin.addingTimeInterval(3_600)), 0)
    }

    func testChangingIntervalKeepsElapsedTime() {
        var schedule = ReminderSchedule(startDate: origin, interval: 45 * 60)
        let now = origin.addingTimeInterval(40 * 60)

        schedule.changeInterval(to: 60 * 60)

        // 已经走过的 40 分钟必须保留：改设置不该把进度清零（这曾经是个 bug）。
        XCTAssertEqual(schedule.remaining(at: now), 20 * 60)
        XCTAssertEqual(schedule.startDate, origin)
    }

    func testShorteningIntervalBelowElapsedMakesItDueImmediately() {
        var schedule = ReminderSchedule(startDate: origin, interval: 45 * 60)
        let now = origin.addingTimeInterval(40 * 60)

        schedule.changeInterval(to: 20 * 60)

        XCTAssertTrue(schedule.isDue(at: now))
        XCTAssertEqual(schedule.remaining(at: now), 0)
    }

    func testRestartBeginsANewRound() {
        var schedule = ReminderSchedule(startDate: origin, interval: 1_800)
        let now = origin.addingTimeInterval(1_700)

        schedule.restart(at: now, interval: 600)

        XCTAssertEqual(schedule.remaining(at: now), 600)
        XCTAssertEqual(schedule.fireDate, now.addingTimeInterval(600))
    }

    func testPostponePushesTheWholeRoundForward() {
        var schedule = ReminderSchedule(startDate: origin, interval: 1_800)
        let now = origin.addingTimeInterval(600)

        schedule.postpone(by: 90)

        // 冻结的 90 秒补回去之后，剩余时间比冻结前多 90 秒。
        XCTAssertEqual(schedule.remaining(at: now), 1_200 + 90)
    }
}

final class LockRecoveryTests: XCTestCase {
    private let threshold: TimeInterval = 2 * 60

    func testShortLockResetsNothingAndGivesBackTheFrozenTime() {
        let plan = LockRecovery.plan(lockedDuration: 45, threshold: threshold)

        XCTAssertEqual(plan.resetTypes, [])
        XCTAssertEqual(plan.postpone, 45)
    }

    func testLongLockResetsEyeAndStandButNeverWater() {
        let plan = LockRecovery.plan(lockedDuration: 20 * 60, threshold: threshold)

        XCTAssertEqual(plan.resetTypes, [.eyeRest, .stand])
        XCTAssertFalse(plan.resetTypes.contains(.water))
        XCTAssertEqual(plan.postpone, 0)
    }

    func testExactlyAtThresholdCountsAsARealBreak() {
        let plan = LockRecovery.plan(lockedDuration: threshold, threshold: threshold)

        XCTAssertEqual(plan.resetTypes, [.eyeRest, .stand])
    }
}
