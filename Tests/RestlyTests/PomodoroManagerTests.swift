import XCTest
@testable import Restly

/// 只覆盖不触发 Toast 的路径 —— presentToast 会真的弹浮窗放音效，
/// 那条链路靠 `--show-pomodoro-preview` 和 `--development-mode` 人工验证
/// （ToastManager 从来没有测试基础设施，维持现状）。
final class PomodoroManagerTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 2_000)

    @MainActor
    private func makeManager(
        now: Date,
        defaults: UserDefaults,
        settings: ReminderSettings? = nil
    ) -> PomodoroManager {
        PomodoroManager(
            settings: settings ?? ReminderSettings(defaults: defaults),
            toastManager: ToastManager(),
            runtimeConfiguration: RuntimeConfiguration(isDevelopmentMode: false, showsEyeRestOnLaunch: false),
            defaults: defaults,
            now: now
        )
    }

    @MainActor
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "PomodoroManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    @MainActor
    func testInitRestoresRunningSessionFromStoredEnd() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let endsAt = origin.addingTimeInterval(20 * 60)
        defaults.set("focus", forKey: "pomodoroPhase")
        defaults.set("running", forKey: "pomodoroStatus")
        defaults.set(endsAt, forKey: "pomodoroEndsAt")
        defaults.set(50 * 60, forKey: "pomodoroFocusSecondsToday")
        defaults.set(2, forKey: "pomodoroFocusInCycle")

        let manager = makeManager(now: origin.addingTimeInterval(60), defaults: defaults)

        XCTAssertEqual(manager.session.phase, .focus)
        XCTAssertEqual(manager.session.focusSecondsToday, 50 * 60)
        guard case .running(let restoredEnd) = manager.session.status else {
            return XCTFail("存档未过期时应恢复为计时中")
        }
        XCTAssertEqual(restoredEnd, endsAt)
        XCTAssertEqual(manager.countdownText(at: origin.addingTimeInterval(60)), "19:00")
    }

    @MainActor
    func testInitWithExpiredFocusCountsItCompleteAndLandsIdle() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("focus", forKey: "pomodoroPhase")
        defaults.set("running", forKey: "pomodoroStatus")
        defaults.set(origin.addingTimeInterval(25 * 60), forKey: "pomodoroEndsAt")
        defaults.set(25 * 60, forKey: "pomodoroFocusSecondsToday")
        defaults.set(1, forKey: "pomodoroFocusInCycle")
        defaults.set(25 * 60, forKey: "pomodoroPhaseDuration")

        // 重启耗时超过了剩余时间：这颗番茄按已完成计，但不自动开始下一段。
        let manager = makeManager(now: origin.addingTimeInterval(3 * 60 * 60), defaults: defaults)

        XCTAssertTrue(manager.isIdle)
        XCTAssertEqual(manager.session.focusSecondsToday, 50 * 60)
        XCTAssertEqual(manager.session.focusCountInCycle, 2)
        XCTAssertNil(manager.countdownText(at: Date()))
    }

    @MainActor
    func testInitAcrossMidnightResetsTodayCount() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(80 * 60, forKey: "pomodoroFocusSecondsToday")
        defaults.set(Calendar.current.startOfDay(for: origin.addingTimeInterval(-24 * 60 * 60)), forKey: "pomodoroDayAnchor")

        let manager = makeManager(now: origin, defaults: defaults)

        XCTAssertEqual(manager.session.focusSecondsToday, 0)
    }

    @MainActor
    func testStartFocusRoundTripsThroughPersistence() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = makeManager(now: origin, defaults: defaults)
        first.startFocus()

        // 起段后立刻落盘：第二个 manager 读回同一个计时中的专注。
        XCTAssertEqual(defaults.string(forKey: "pomodoroPhase"), "focus")
        XCTAssertEqual(defaults.string(forKey: "pomodoroStatus"), "running")
        let storedEnd = defaults.object(forKey: "pomodoroEndsAt") as? Date
        XCTAssertNotNil(storedEnd)

        let second = makeManager(now: origin.addingTimeInterval(10), defaults: defaults)
        XCTAssertEqual(second.session.phase, .focus)
        guard case .running(let restoredEnd) = second.session.status else {
            return XCTFail("读回后应仍是计时中")
        }
        XCTAssertEqual(restoredEnd, storedEnd)
    }

    @MainActor
    func testStopClearsPersistedSessionKeysButKeepsCounters() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(50 * 60, forKey: "pomodoroFocusSecondsToday")
        defaults.set(Calendar.current.startOfDay(for: origin), forKey: "pomodoroDayAnchor")

        let manager = makeManager(now: origin, defaults: defaults)
        manager.startFocus()
        manager.stop()

        // 停止后：进行中的段清干净，今天的累计时长保留 —— 那是已经发生的事实。
        XCTAssertNil(defaults.object(forKey: "pomodoroPhase"))
        XCTAssertNil(defaults.object(forKey: "pomodoroStatus"))
        XCTAssertNil(defaults.object(forKey: "pomodoroEndsAt"))
        XCTAssertNil(defaults.object(forKey: "pomodoroPhaseDuration"))
        XCTAssertEqual(defaults.integer(forKey: "pomodoroFocusSecondsToday"), 50 * 60)
        XCTAssertTrue(manager.isIdle)
    }

    @MainActor
    func testLockFreezesRunningSessionAndUnlockResumesIt() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = makeManager(now: origin, defaults: defaults)
        manager.startFocus()

        manager.screenDidBecomeUnavailable()

        // 冻结后手动暂停不生效：解锁要自动续上，别把用户冻在半路。
        let frozenBefore = manager.session.remaining(at: Date()) ?? 0
        manager.pause()
        XCTAssertEqual(manager.session.remaining(at: Date()), frozenBefore)

        manager.screenDidBecomeAvailable(after: 45)

        guard case .running = manager.session.status else {
            return XCTFail("解锁后应自动恢复计时中")
        }
        XCTAssertNotNil(manager.countdownText(at: Date()))
    }

    @MainActor
    func testUserPausedSessionStaysPausedAcrossLock() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = makeManager(now: origin, defaults: defaults)
        manager.startFocus()
        manager.pause()

        manager.screenDidBecomeUnavailable()
        manager.screenDidBecomeAvailable(after: 45)

        // 解锁不该替用户按恢复。
        guard case .paused = manager.session.status else {
            return XCTFail("手动暂停在锁屏往返后应保持暂停")
        }
        let storedRemaining = defaults.double(forKey: "pomodoroPausedRemaining")
        XCTAssertGreaterThan(storedRemaining, 0)
        XCTAssertLessThanOrEqual(storedRemaining, 25 * 60)
        XCTAssertEqual(defaults.string(forKey: "pomodoroStatus"), "paused")
    }
}
