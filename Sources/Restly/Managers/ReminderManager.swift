import AppKit
import Foundation

@MainActor
final class ReminderManager: NSObject, ObservableObject {
    @Published private(set) var countdowns: [ReminderType: ReminderCountdown]
    @Published private(set) var snoozedUntil: [ReminderType: Date] = [:]
    @Published private(set) var pauseUntil: Date?
    @Published private(set) var activityState: ActivityState = .active
    @Published private(set) var idleSeconds: TimeInterval = 0

    let runtimeConfiguration: RuntimeConfiguration

    private let settings: ReminderSettings
    private let activityMonitor: ActivityMonitor
    private let toastManager: ToastManager
    private let overlayController: EyeRestOverlayController
    private let defaults: UserDefaults
    private let schedulerInterval: TimeInterval = 5
    private var scheduler: Timer?
    private var lastTick = Date()

    init(
        settings: ReminderSettings,
        activityMonitor: ActivityMonitor,
        toastManager: ToastManager,
        overlayController: EyeRestOverlayController,
        runtimeConfiguration: RuntimeConfiguration = .current,
        defaults: UserDefaults = .standard
    ) {
        self.settings = settings
        self.activityMonitor = activityMonitor
        self.toastManager = toastManager
        self.overlayController = overlayController
        self.runtimeConfiguration = runtimeConfiguration
        self.defaults = defaults
        countdowns = Dictionary(
            uniqueKeysWithValues: ReminderType.allCases.map {
                ($0, ReminderCountdown(duration: runtimeConfiguration.interval(for: $0, settings: settings)))
            }
        )

        if let storedPause = defaults.object(forKey: Keys.pauseUntil) as? Date,
           storedPause > Date() {
            pauseUntil = storedPause
        }

        super.init()

        settings.onChange = { [weak self] in
            self?.handleSettingsChanged()
        }
        toastManager.actionHandler = { [weak self] type, action in
            self?.handleAction(action, for: type)
        }
        observeWorkspaceEvents()
        sampleAndAdvance()
        startScheduler()
        if runtimeConfiguration.showsEyeRestOnLaunch {
            Timer.scheduledTimer(
                timeInterval: 1,
                target: self,
                selector: #selector(showEyeRestOnLaunch),
                userInfo: nil,
                repeats: false
            )
        }
    }

    func remainingDescription(for type: ReminderType, now: Date = Date()) -> String {
        guard settings.isEnabled(type) else { return "已关闭" }
        if isPaused(at: now) { return "已暂停" }

        let remaining: TimeInterval
        if let snoozeDate = snoozedUntil[type], snoozeDate > now {
            remaining = snoozeDate.timeIntervalSince(now)
        } else {
            remaining = countdowns[type]?.remaining ?? interval(for: type)
        }

        if remaining < 60 {
            return "\(max(1, Int(ceil(remaining)))) sec"
        }
        return "\(max(1, Int(ceil(remaining / 60)))) min"
    }

    func pause(for minutes: Int) {
        let date = Date().addingTimeInterval(TimeInterval(minutes * 60))
        pauseUntil = date
        defaults.set(date, forKey: Keys.pauseUntil)
        overlayController.dismiss()
        lastTick = Date()
    }

    func resume() {
        pauseUntil = nil
        defaults.removeObject(forKey: Keys.pauseUntil)
        lastTick = Date()
    }

    func isPaused(at date: Date = Date()) -> Bool {
        guard let pauseUntil else { return false }
        return pauseUntil > date
    }

    func pauseDescription(now: Date = Date()) -> String? {
        guard let pauseUntil, pauseUntil > now else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return "提醒已暂停至 \(formatter.string(from: pauseUntil))"
    }

    func complete(_ type: ReminderType) {
        snoozedUntil[type] = nil
        reset(type)
    }

    func skip(_ type: ReminderType) {
        snoozedUntil[type] = nil
        reset(type)
    }

    func snooze(_ type: ReminderType, minutes: Int = 10) {
        snoozedUntil[type] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        reset(type)
    }

    func triggerEyeRestForTesting() {
        guard runtimeConfiguration.isDevelopmentMode else { return }
        trigger(.eyeRest)
    }

    func refreshActivityStatus() {
        sampleAndAdvance()
    }

    private func startScheduler() {
        scheduler = Timer.scheduledTimer(
            timeInterval: schedulerInterval,
            target: self,
            selector: #selector(schedulerDidFire),
            userInfo: nil,
            repeats: true
        )
        if let scheduler {
            RunLoop.main.add(scheduler, forMode: .common)
        }
    }

    @objc private func schedulerDidFire() {
        sampleAndAdvance()
    }

    @objc private func showEyeRestOnLaunch() {
        trigger(.eyeRest)
    }

    private func sampleAndAdvance(now: Date = Date()) {
        let elapsed = min(max(0, now.timeIntervalSince(lastTick)), schedulerInterval * 2)
        lastTick = now

        let previousActivityState = activityState
        let sample = activityMonitor.sample(settings: settings)
        activityState = sample.state
        idleSeconds = sample.idleSeconds

        if sample.state == .away, previousActivityState != .away {
            snoozedUntil[.eyeRest] = nil
            snoozedUntil[.stand] = nil
            reset(.eyeRest)
            reset(.stand)
        }

        if let pauseUntil, pauseUntil <= now {
            self.pauseUntil = nil
            defaults.removeObject(forKey: Keys.pauseUntil)
        }
        guard !isPaused(at: now), sample.state == .active else { return }

        for type in ReminderType.allCases where settings.isEnabled(type) {
            if let snoozeDate = snoozedUntil[type] {
                if snoozeDate <= now {
                    snoozedUntil[type] = nil
                    trigger(type)
                }
                continue
            }

            guard var countdown = countdowns[type] else { continue }
            let didReachZero = countdown.advance(by: elapsed, whileActive: true)
            countdowns[type] = countdown
            if didReachZero {
                trigger(type)
            }
        }
    }

    private func trigger(_ type: ReminderType) {
        guard settings.isEnabled(type), !isPaused() else { return }
        reset(type)

        switch type {
        case .eyeRest:
            overlayController.show(durationSeconds: settings.eyeRestDurationSeconds) { [weak self] action in
                self?.handleAction(action, for: .eyeRest)
            }
        case .water, .stand:
            let intervalMinutes = type == .water
                ? settings.waterIntervalMinutes
                : settings.standIntervalMinutes
            toastManager.show(type, intervalMinutes: intervalMinutes)
        }
    }

    private func handleAction(_ action: ReminderAction, for type: ReminderType) {
        switch action {
        case .completed:
            complete(type)
        case .skipped:
            skip(type)
        case .snoozed:
            snooze(type)
        }
    }

    private func reset(_ type: ReminderType) {
        var countdown = countdowns[type] ?? ReminderCountdown(duration: interval(for: type))
        countdown.reset(to: interval(for: type))
        countdowns[type] = countdown
    }

    private func resetAll() {
        snoozedUntil.removeAll()
        for type in ReminderType.allCases {
            reset(type)
        }
    }

    private func interval(for type: ReminderType) -> TimeInterval {
        runtimeConfiguration.interval(for: type, settings: settings)
    }

    private func handleSettingsChanged() {
        resetAll()
        lastTick = Date()
    }

    private func observeWorkspaceEvents() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(systemWillSuspend),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemDidResume),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemWillSuspend),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemDidResume),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func systemWillSuspend() {
        activityMonitor.markSleeping()
        activityState = .sleeping
        overlayController.dismiss()
        lastTick = Date()
    }

    @objc private func systemDidResume() {
        activityMonitor.markAwake()
        resetAll()
        lastTick = Date()
        sampleAndAdvance()
    }

    private enum Keys {
        static let pauseUntil = "globalPauseUntil"
    }
}
