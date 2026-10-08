import AppKit
import Foundation

@MainActor
final class ReminderManager: ObservableObject {
    @Published private(set) var schedules: [ReminderType: ReminderSchedule]
    @Published private(set) var snoozedUntil: [ReminderType: Date] = [:]
    @Published private(set) var pauseUntil: Date?
    @Published private(set) var isScreenAvailable = true

    let runtimeConfiguration: RuntimeConfiguration

    private let settings: ReminderSettings
    private let toastManager: ToastManager
    private let overlayController: EyeRestOverlayController
    private let screenLockManager: ScreenLockManager
    private let defaults: UserDefaults

    /// 只有一个一次性定时器，直接定到最近的那个触发时刻。
    /// 从前是每 5 秒轮询一次去采样键鼠 idle；现在计时是纯日期算术，不需要滴答，
    /// 常态下每几十分钟才唤醒一次 CPU。
    private var timer: Timer?

    /// 超过这个时长的暂停视为「无限期」。用宽松比较而不是等号，
    /// 免得 Date 经过 UserDefaults 往返之后精度对不上。
    private static let indefinitePauseHorizon: TimeInterval = 365 * 24 * 60 * 60

    init(
        settings: ReminderSettings,
        toastManager: ToastManager,
        overlayController: EyeRestOverlayController,
        screenLockManager: ScreenLockManager,
        runtimeConfiguration: RuntimeConfiguration = .current,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        self.settings = settings
        self.toastManager = toastManager
        self.overlayController = overlayController
        self.screenLockManager = screenLockManager
        self.runtimeConfiguration = runtimeConfiguration
        self.defaults = defaults
        schedules = Dictionary(
            uniqueKeysWithValues: ReminderType.allCases.map {
                (
                    $0,
                    ReminderSchedule(
                        startDate: now,
                        interval: runtimeConfiguration.interval(for: $0, settings: settings)
                    )
                )
            }
        )

        if let storedPause = defaults.object(forKey: Keys.pauseUntil) as? Date,
           storedPause > now {
            pauseUntil = storedPause
        }

        settings.onChange = { [weak self] change in
            self?.handleSettingsChange(change)
        }
        toastManager.actionHandler = { [weak self] type, action in
            self?.handleAction(action, for: type)
        }
        // 屏幕状态的订阅与分发在 AppEnvironment 里统一接线 ——
        // ScreenStateMonitor 的回调是一次性闭包属性，订阅者不止一个之后
        // 由组合根 fan-out 最直观。
        rescheduleTimer(now: now)

        if runtimeConfiguration.showsEyeRestOnLaunch {
            let launchTimer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.trigger(.eyeRest, at: Date()) }
            }
            RunLoop.main.add(launchTimer, forMode: .common)
        }
    }

    // MARK: - 对外查询

    func remainingDescription(for type: ReminderType, now: Date = Date()) -> String {
        guard settings.isEnabled(type) else { return "已关闭" }
        if isPaused(at: now) { return "已暂停" }
        if !isScreenAvailable { return "已停止" }

        let remaining: TimeInterval
        if let snoozeDate = snoozedUntil[type], snoozeDate > now {
            remaining = snoozeDate.timeIntervalSince(now)
        } else {
            remaining = schedules[type]?.remaining(at: now) ?? interval(for: type)
        }

        if remaining < 60 {
            return "\(max(1, Int(ceil(remaining)))) 秒"
        }
        return "\(max(1, Int(ceil(remaining / 60)))) 分钟"
    }

    func isPaused(at date: Date = Date()) -> Bool {
        guard let pauseUntil else { return false }
        return pauseUntil > date
    }

    var isPausedIndefinitely: Bool {
        guard let pauseUntil else { return false }
        return pauseUntil.timeIntervalSinceNow > Self.indefinitePauseHorizon
    }

    func pauseDescription(now: Date = Date()) -> String? {
        guard let pauseUntil, pauseUntil > now else { return nil }
        if isPausedIndefinitely { return "提醒已暂停，等你手动恢复" }
        // 用系统短时间格式，跟随用户的 12/24 小时制设置。
        return "提醒已暂停至 \(pauseUntil.formatted(date: .omitted, time: .shortened))"
    }

    /// 菜单打开时调用，补上关闭期间已经到点的提醒。
    func refresh() {
        fireDueReminders()
    }

    // MARK: - 用户操作

    func pause(for minutes: Int) {
        applyPause(until: Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    func pauseIndefinitely() {
        applyPause(until: .distantFuture)
    }

    func resume() {
        pauseUntil = nil
        defaults.removeObject(forKey: Keys.pauseUntil)
        // 主动暂停结束就一切从头开始，比「接着上次继续」更好预期。
        restartAll(at: Date())
        resumeToastQueueIfAllowed()
        rescheduleTimer()
    }

    func complete(_ type: ReminderType) {
        snoozedUntil[type] = nil
        restart(type, at: Date())
        rescheduleTimer()
    }

    func skip(_ type: ReminderType) {
        complete(type)
    }

    func snooze(_ type: ReminderType, minutes: Int = 10) {
        snoozedUntil[type] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        restart(type, at: Date())
        rescheduleTimer()
    }

    func triggerEyeRestForTesting() {
        guard runtimeConfiguration.isDevelopmentMode else { return }
        trigger(.eyeRest, at: Date())
    }

    // MARK: - 定时器

    private func rescheduleTimer(now: Date = Date()) {
        timer?.invalidate()
        timer = nil
        guard isScreenAvailable else { return }

        if let pauseUntil, pauseUntil > now {
            // 无限期暂停不需要定时器，等用户手动恢复。
            guard !isPausedIndefinitely else { return }
            scheduleTimer(at: pauseUntil, now: now)
            return
        }

        guard let next = nextWakeDate(now: now) else { return }
        scheduleTimer(at: next, now: now)
    }

    private func scheduleTimer(at date: Date, now: Date) {
        let delay = max(0.5, date.timeIntervalSince(now))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDueReminders() }
        }
        // 分钟级的提醒不需要秒级精度，留出余量让系统合并唤醒。
        timer.tolerance = min(30, delay * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func nextWakeDate(now: Date) -> Date? {
        ReminderType.allCases
            .filter { settings.isEnabled($0) }
            .compactMap { snoozedUntil[$0] ?? schedules[$0]?.fireDate }
            .min()
    }

    private func fireDueReminders(now: Date = Date()) {
        if let pauseUntil, pauseUntil <= now {
            self.pauseUntil = nil
            defaults.removeObject(forKey: Keys.pauseUntil)
            restartAll(at: now)
            resumeToastQueueIfAllowed()
            rescheduleTimer(now: now)
            return
        }

        guard isScreenAvailable, !isPaused(at: now) else {
            rescheduleTimer(now: now)
            return
        }

        for type in ReminderType.allCases where settings.isEnabled(type) {
            if let snoozeDate = snoozedUntil[type] {
                if snoozeDate <= now {
                    snoozedUntil[type] = nil
                    trigger(type, at: now)
                }
                continue
            }
            if schedules[type]?.isDue(at: now) == true {
                trigger(type, at: now)
            }
        }

        rescheduleTimer(now: now)
    }

    // MARK: - 触发

    private func trigger(_ type: ReminderType, at now: Date) {
        guard settings.isEnabled(type), !isPaused(at: now) else { return }
        restart(type, at: now)

        switch type {
        case .eyeRest:
            toastManager.showEyeRestHeadsUp(
                onStart: { [weak self] in self?.beginEyeRestOverlay() },
                onSnooze: { [weak self] in self?.snooze(.eyeRest, minutes: 5) }
            )
        case .water, .stand:
            toastManager.show(
                type,
                intervalMinutes: settings.intervalMinutes(for: type),
                autoDismiss: settings.autoDismissHealthToasts
            )
        }
    }

    private func beginEyeRestOverlay() {
        guard settings.eyeEnabled, !isPaused() else {
            resumeToastQueueIfAllowed()
            return
        }

        toastManager.suspendQueue()
        overlayController.show(durationSeconds: settings.eyeRestDurationSeconds) { [weak self] action in
            guard let self else { return }
            self.resumeToastQueueIfAllowed()
            self.handleAction(action, for: .eyeRest)
        }
    }

    private func handleAction(_ action: ReminderAction, for type: ReminderType) {
        switch action {
        case .completed:
            complete(type)
            if type == .stand, settings.lockScreenAfterStanding {
                toastManager.showScreenLockCountdown { [weak self] in
                    guard let self, self.settings.lockScreenAfterStanding else { return }
                    self.screenLockManager.lockScreen()
                }
            }
        case .skipped:
            skip(type)
        case .snoozed:
            snooze(type, minutes: type == .eyeRest ? 10 : 5)
        }
    }

    // MARK: - 屏幕状态
    // 供 AppEnvironment 的 fan-out 调用，不在本类里订阅 ScreenStateMonitor。

    func handleScreenUnavailable() {
        isScreenAvailable = false
        timer?.invalidate()
        timer = nil
        toastManager.cancelEyeRestHeadsUp()
        toastManager.cancelScreenLockCountdown()
        // 别把浮窗留在锁屏后面，回来看到一个几小时前的提醒没有意义。
        toastManager.dismissActiveHealthToast()
        toastManager.suspendQueue()
        overlayController.dismiss()
    }

    func handleScreenAvailable(after lockedDuration: TimeInterval) {
        isScreenAvailable = true
        let now = Date()
        let recovery = LockRecovery.plan(
            lockedDuration: lockedDuration,
            threshold: TimeInterval(settings.lockResetThresholdMinutes * 60)
        )

        for type in recovery.resetTypes {
            snoozedUntil[type] = nil
            restart(type, at: now)
        }
        if recovery.postpone > 0 {
            // 锁屏太短，不算休息：护眼和站立在锁屏期间是停着的，把那段补回去。
            // 喝水不在此列 —— 它按纯墙钟走，锁屏期间照样在流逝。
            for type in [ReminderType.eyeRest, .stand] {
                schedules[type]?.postpone(by: recovery.postpone)
            }
        }

        resumeToastQueueIfAllowed()
        fireDueReminders(now: now)
    }

    // MARK: - 内部

    private func applyPause(until date: Date) {
        pauseUntil = date
        defaults.set(date, forKey: Keys.pauseUntil)
        toastManager.cancelEyeRestHeadsUp()
        toastManager.cancelScreenLockCountdown()
        toastManager.dismissActiveHealthToast()
        toastManager.suspendQueue()
        overlayController.dismiss()
        rescheduleTimer()
    }

    private func handleSettingsChange(_ change: SettingsChange) {
        let now = Date()
        switch change {
        case .interval(let type):
            // 只换间隔，保留已经走过的时间。
            schedules[type]?.changeInterval(to: interval(for: type))
        case .enabled(let type):
            snoozedUntil[type] = nil
            restart(type, at: now)
        case .other:
            // 浮窗自动消失、护眼时长、锁屏阈值都不影响正在走的计时。
            break
        }
        toastManager.cancelEyeRestHeadsUp()
        if !settings.lockScreenAfterStanding {
            toastManager.cancelScreenLockCountdown()
        }
        rescheduleTimer(now: now)
    }

    private func restart(_ type: ReminderType, at date: Date) {
        var schedule = schedules[type] ?? ReminderSchedule(startDate: date, interval: interval(for: type))
        schedule.restart(at: date, interval: interval(for: type))
        schedules[type] = schedule
    }

    private func restartAll(at date: Date) {
        snoozedUntil.removeAll()
        for type in ReminderType.allCases {
            restart(type, at: date)
        }
    }

    private func interval(for type: ReminderType) -> TimeInterval {
        runtimeConfiguration.interval(for: type, settings: settings)
    }

    private func resumeToastQueueIfAllowed() {
        guard isScreenAvailable, !isPaused(), !overlayController.isVisible else { return }
        toastManager.resumeQueue()
    }

    private enum Keys {
        static let pauseUntil = "globalPauseUntil"
    }
}
