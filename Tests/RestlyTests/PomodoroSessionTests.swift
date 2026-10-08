import XCTest
@testable import Restly

final class PomodoroSessionTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 1_000)
    /// 固定 UTC 的公历，跨天测试不随测试机的时区漂移。
    private let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var cycle: PomodoroSession.Cycle {
        PomodoroSession.Cycle(
            focus: 25 * 60,
            shortBreak: 5 * 60,
            longBreak: 15 * 60,
            longBreakEvery: 4
        )
    }

    private func makeSession(now: Date) -> PomodoroSession {
        PomodoroSession(now: now, calendar: utcCalendar)
    }

    // MARK: - 墙钟计时

    func testRemainingAndIsDueComeFromWallClock() {
        var session = makeSession(now: origin)
        session.start(.focus, at: origin, cycle: cycle)

        XCTAssertEqual(session.remaining(at: origin.addingTimeInterval(31)), 25 * 60 - 31)
        XCTAssertFalse(session.isDue(at: origin.addingTimeInterval(25 * 60 - 1)))
        XCTAssertTrue(session.isDue(at: origin.addingTimeInterval(25 * 60)))
        // 过了结束时刻之后剩余时间钳在 0，不会变成负数。
        XCTAssertEqual(session.remaining(at: origin.addingTimeInterval(30 * 60)), 0)
    }

    func testPauseFreezesRemainingAndResumeReanchorsEnd() {
        var session = makeSession(now: origin)
        session.start(.focus, at: origin, cycle: cycle)

        session.pause(at: origin.addingTimeInterval(5 * 60))
        // 暂停期间剩余时间不再流逝。
        XCTAssertEqual(session.remaining(at: origin.addingTimeInterval(20 * 60)), 20 * 60)
        XCTAssertFalse(session.isDue(at: origin.addingTimeInterval(20 * 60)))

        session.resume(at: origin.addingTimeInterval(20 * 60))
        // 恢复时以当下为锚，把冻结的剩余时长重新铺满。
        XCTAssertEqual(session.remaining(at: origin.addingTimeInterval(20 * 60)), 20 * 60)
        XCTAssertTrue(session.isDue(at: origin.addingTimeInterval(40 * 60)))
    }

    // MARK: - 完成与循环

    func testCompletingFocusIncrementsCountersAndStartsBreak() {
        var session = makeSession(now: origin)
        session.start(.focus, at: origin, cycle: cycle)
        let now = origin.addingTimeInterval(25 * 60)

        let outcome = session.completePhase(at: now, cycle: cycle, autoStartNext: true)

        XCTAssertEqual(outcome, .started(.shortBreak))
        // 完整走完的专注按标称时长计入今日总时长。
        XCTAssertEqual(session.focusSecondsToday, 25 * 60)
        XCTAssertEqual(session.focusCountInCycle, 1)
        XCTAssertEqual(session.remaining(at: now), 5 * 60)
    }

    func testCompletingFocusWithoutAutoStartWaitsForUser() {
        var session = makeSession(now: origin)
        session.start(.focus, at: origin, cycle: cycle)

        let outcome = session.completePhase(
            at: origin.addingTimeInterval(25 * 60),
            cycle: cycle,
            autoStartNext: false
        )

        XCTAssertEqual(outcome, .awaiting(.shortBreak))
        XCTAssertEqual(session.phase, .shortBreak)
        XCTAssertEqual(session.status, .awaitingStart)
        XCTAssertNil(session.remaining(at: origin.addingTimeInterval(25 * 60)))
    }

    func testLongBreakFallsOnEveryNthCompletedFocus() {
        var session = makeSession(now: origin)

        // 连做八个专注（每次跳过休息直接开始下一个），第 4、8 个之后该是长休息。
        var breakKinds: [PomodoroSession.Phase] = []
        for index in 0..<8 {
            session.start(.focus, at: origin, cycle: cycle)
            let outcome = session.completePhase(
                at: origin.addingTimeInterval(25 * 60),
                cycle: cycle,
                autoStartNext: false
            )
            guard case .awaiting(let kind) = outcome else {
                return XCTFail("第 \(index + 1) 个专注后应停在就绪态，得到 \(outcome)")
            }
            breakKinds.append(kind)
            // 就绪态里跳过休息，直接回到下一个专注。
            _ = session.skip(cycle: cycle)
        }

        XCTAssertEqual(breakKinds, [
            .shortBreak, .shortBreak, .shortBreak, .longBreak,
            .shortBreak, .shortBreak, .shortBreak, .longBreak,
        ])
        XCTAssertEqual(session.focusSecondsToday, 8 * 25 * 60)
        XCTAssertEqual(session.focusCountInCycle, 8)
    }

    func testSkipDoesNotIncrementAnyCounter() {
        var session = makeSession(now: origin)
        session.start(.focus, at: origin, cycle: cycle)

        let outcome = session.skip(cycle: cycle)

        XCTAssertEqual(outcome, .awaiting(.shortBreak))
        XCTAssertEqual(session.focusSecondsToday, 0)
        XCTAssertEqual(session.focusCountInCycle, 0)
        XCTAssertEqual(session.status, .awaitingStart)
    }

    func testSkipFromAwaitingBreakMovesToFocusAndFromAwaitingFocusStops() {
        var session = makeSession(now: origin)
        session.start(.focus, at: origin, cycle: cycle)
        _ = session.completePhase(
            at: origin.addingTimeInterval(25 * 60),
            cycle: cycle,
            autoStartNext: false
        )

        // 就绪等休息时跳过：直接回到下一个专注的就绪态，循环计数不动。
        XCTAssertEqual(session.skip(cycle: cycle), .awaiting(.focus))
        XCTAssertEqual(session.phase, .focus)
        XCTAssertEqual(session.focusSecondsToday, 25 * 60)
        XCTAssertEqual(session.focusCountInCycle, 1)

        // 就绪等专注时跳过：等于放弃这一轮循环。
        XCTAssertEqual(session.skip(cycle: cycle), .becameIdle)
        XCTAssertTrue(session.isIdle)
        XCTAssertEqual(session.focusCountInCycle, 0)
        // 今日累计时长是已经发生的事实，停止不清零。
        XCTAssertEqual(session.focusSecondsToday, 25 * 60)
    }

    func testStopKeepsTodayCountAndResetsCycleCounter() {
        var session = makeSession(now: origin)
        session.start(.focus, at: origin, cycle: cycle)
        _ = session.completePhase(
            at: origin.addingTimeInterval(25 * 60),
            cycle: cycle,
            autoStartNext: false
        )

        session.stop()

        XCTAssertTrue(session.isIdle)
        XCTAssertEqual(session.focusSecondsToday, 25 * 60)
        XCTAssertEqual(session.focusCountInCycle, 0)
    }

    // MARK: - 跨天

    func testDayRolloverResetsTodayCountButKeepsCycle() {
        let dayOne = Date(timeIntervalSince1970: 1_730_000_000) // UTC 2024-10-27
        var session = makeSession(now: dayOne)
        session.start(.focus, at: dayOne, cycle: cycle)
        _ = session.completePhase(at: dayOne.addingTimeInterval(25 * 60), cycle: cycle, autoStartNext: false)

        let dayTwo = dayOne.addingTimeInterval(24 * 60 * 60)
        session.rollDayIfNeeded(at: dayTwo, calendar: utcCalendar)

        XCTAssertEqual(session.focusSecondsToday, 0)
        // 循环计数跨天连续：长休息的节奏不该因为睡一觉重排。
        XCTAssertEqual(session.focusCountInCycle, 1)
    }

    // MARK: - 格式

    func testCountdownTextFormatsAsMinutesColonSeconds() {
        XCTAssertEqual(PomodoroSession.countdownText(for: 24 * 60 + 31), "24:31")
        XCTAssertEqual(PomodoroSession.countdownText(for: 5 * 60), "5:00")
        // 不足一秒按一秒算，避免到点前显示 0:00。
        XCTAssertEqual(PomodoroSession.countdownText(for: 0.4), "0:01")
        XCTAssertEqual(PomodoroSession.countdownText(for: 0), "0:00")
        XCTAssertEqual(PomodoroSession.countdownText(for: 120 * 60), "120:00")
    }

    func testFocusSummaryTextScalesFromMinutesToHours() {
        XCTAssertEqual(PomodoroSession.focusSummaryText(secondsToday: 0), "今天还没有完整的专注")
        XCTAssertEqual(PomodoroSession.focusSummaryText(secondsToday: 25 * 60), "今日已专注 25 分钟")
        XCTAssertEqual(PomodoroSession.focusSummaryText(secondsToday: 80 * 60), "今日已专注 1 小时 20 分")
    }

    // MARK: - 重启恢复

    func testRestorationKeepsFutureRunningSession() {
        let endsAt = origin.addingTimeInterval(20 * 60)
        var session = PomodoroSession(snapshot: PomodoroSession.Snapshot(
            phase: .focus,
            status: .running(endsAt: endsAt),
            focusSecondsToday: 50 * 60,
            dayAnchor: utcCalendar.startOfDay(for: origin),
            focusCountInCycle: 2,
            phaseDuration: 25 * 60
        ))

        let outcome = session.resolveAfterRestoration(at: origin.addingTimeInterval(60), calendar: utcCalendar)

        XCTAssertEqual(outcome, .running)
        XCTAssertEqual(session.remaining(at: origin.addingTimeInterval(60)), 19 * 60)
        XCTAssertEqual(session.focusSecondsToday, 50 * 60)
    }

    func testRestorationCountsExpiredFocusAsCompletedAndLandsIdle() {
        var session = PomodoroSession(snapshot: PomodoroSession.Snapshot(
            phase: .focus,
            status: .running(endsAt: origin.addingTimeInterval(25 * 60)),
            focusSecondsToday: 25 * 60,
            dayAnchor: utcCalendar.startOfDay(for: origin),
            focusCountInCycle: 1,
            phaseDuration: 25 * 60
        ))

        // 重启耗时超过了剩余时间：这颗番茄按已完成计，但不自动衔接下一段。
        let outcome = session.resolveAfterRestoration(at: origin.addingTimeInterval(3 * 60 * 60), calendar: utcCalendar)

        XCTAssertEqual(outcome, .expired)
        XCTAssertTrue(session.isIdle)
        XCTAssertEqual(session.focusSecondsToday, 50 * 60)
        XCTAssertEqual(session.focusCountInCycle, 2)
    }

    func testRestorationDropsExpiredBreakWithoutCounting() {
        var session = PomodoroSession(snapshot: PomodoroSession.Snapshot(
            phase: .shortBreak,
            status: .running(endsAt: origin.addingTimeInterval(5 * 60)),
            focusSecondsToday: 100 * 60,
            dayAnchor: utcCalendar.startOfDay(for: origin),
            focusCountInCycle: 4,
            phaseDuration: 5 * 60
        ))

        let outcome = session.resolveAfterRestoration(at: origin.addingTimeInterval(60 * 60), calendar: utcCalendar)

        XCTAssertEqual(outcome, .expired)
        XCTAssertTrue(session.isIdle)
        XCTAssertEqual(session.focusSecondsToday, 100 * 60)
        XCTAssertEqual(session.focusCountInCycle, 4)
    }

    func testRestorationKeepsPausedAndAwaiting() {
        var paused = PomodoroSession(snapshot: PomodoroSession.Snapshot(
            phase: .focus,
            status: .paused(remaining: 12 * 60),
            focusSecondsToday: 25 * 60,
            dayAnchor: utcCalendar.startOfDay(for: origin),
            focusCountInCycle: 1
        ))
        XCTAssertEqual(paused.resolveAfterRestoration(at: origin, calendar: utcCalendar), .paused)
        XCTAssertEqual(paused.remaining(at: origin), 12 * 60)

        var awaiting = PomodoroSession(snapshot: PomodoroSession.Snapshot(
            phase: .shortBreak,
            status: .awaitingStart,
            focusSecondsToday: 25 * 60,
            dayAnchor: utcCalendar.startOfDay(for: origin),
            focusCountInCycle: 1
        ))
        XCTAssertEqual(awaiting.resolveAfterRestoration(at: origin, calendar: utcCalendar), .awaiting)
        XCTAssertEqual(awaiting.phase, .shortBreak)
    }

    func testRestorationAcrossMidnightCountsExpiredFocusIntoNewDay() {
        let dayOne = Date(timeIntervalSince1970: 1_730_000_000)
        var session = PomodoroSession(snapshot: PomodoroSession.Snapshot(
            phase: .focus,
            status: .running(endsAt: dayOne.addingTimeInterval(25 * 60)),
            focusSecondsToday: 75 * 60,
            dayAnchor: utcCalendar.startOfDay(for: dayOne),
            focusCountInCycle: 3,
            phaseDuration: 25 * 60
        ))

        // 昨天到期的专注，今天打开应用才恢复 —— 计入今天的总时长。
        let outcome = session.resolveAfterRestoration(
            at: dayOne.addingTimeInterval(24 * 60 * 60),
            calendar: utcCalendar
        )

        XCTAssertEqual(outcome, .expired)
        XCTAssertEqual(session.focusSecondsToday, 25 * 60)
        XCTAssertEqual(session.focusCountInCycle, 4)
    }
}
