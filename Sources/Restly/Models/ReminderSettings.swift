import Foundation

/// 设置变化的种类。
///
/// 从前 `onChange` 不带参数，任何一项设置变动都会触发 `resetAll()` ——
/// 拨一下「浮窗自动消失」，已经走了 29 分钟的护眼计时就归零。分类之后
/// 只有真正影响计时的改动才动计时。
enum SettingsChange: Equatable, Sendable {
    /// 某个提醒的间隔变了：换间隔，但保留已经走过的时间。
    case interval(ReminderType)
    /// 某个提醒被开启或关闭：那一项从零开始。
    case enabled(ReminderType)
    /// 其它设置（浮窗自动消失、护眼时长、锁屏重置阈值、锁屏开关）：不碰任何计时。
    case other
}

@MainActor
final class ReminderSettings: ObservableObject {
    @Published var waterEnabled: Bool {
        didSet { persist(waterEnabled, forKey: Keys.waterEnabled, change: .enabled(.water)) }
    }

    @Published var waterIntervalMinutes: Int {
        didSet { persist(waterIntervalMinutes, forKey: Keys.waterIntervalMinutes, change: .interval(.water)) }
    }

    @Published var eyeEnabled: Bool {
        didSet { persist(eyeEnabled, forKey: Keys.eyeEnabled, change: .enabled(.eyeRest)) }
    }

    @Published var eyeIntervalMinutes: Int {
        didSet { persist(eyeIntervalMinutes, forKey: Keys.eyeIntervalMinutes, change: .interval(.eyeRest)) }
    }

    @Published var eyeRestDurationSeconds: Int {
        didSet { persist(eyeRestDurationSeconds, forKey: Keys.eyeRestDurationSeconds, change: .other) }
    }

    @Published var standEnabled: Bool {
        didSet { persist(standEnabled, forKey: Keys.standEnabled, change: .enabled(.stand)) }
    }

    @Published var standIntervalMinutes: Int {
        didSet { persist(standIntervalMinutes, forKey: Keys.standIntervalMinutes, change: .interval(.stand)) }
    }

    /// 锁屏多久才算「真的休息过一次」。短于这个值当作误触，什么都不重置。
    @Published var lockResetThresholdMinutes: Int {
        didSet { persist(lockResetThresholdMinutes, forKey: Keys.lockResetThresholdMinutes, change: .other) }
    }

    @Published var autoDismissHealthToasts: Bool {
        didSet { persist(autoDismissHealthToasts, forKey: Keys.autoDismissHealthToasts, change: .other) }
    }

    @Published var lockScreenAfterStanding: Bool {
        didSet { persist(lockScreenAfterStanding, forKey: Keys.lockScreenAfterStanding, change: .other) }
    }

    // MARK: - 番茄钟
    // 全部是 .other：不影响健康提醒的计时。番茄钟自己不接 onChange ——
    // 改时长只对下一段生效，进行中的阶段照旧走完。

    @Published var pomodoroFocusMinutes: Int {
        didSet { persist(pomodoroFocusMinutes, forKey: Keys.pomodoroFocusMinutes, change: .other) }
    }

    @Published var pomodoroShortBreakMinutes: Int {
        didSet { persist(pomodoroShortBreakMinutes, forKey: Keys.pomodoroShortBreakMinutes, change: .other) }
    }

    @Published var pomodoroLongBreakMinutes: Int {
        didSet { persist(pomodoroLongBreakMinutes, forKey: Keys.pomodoroLongBreakMinutes, change: .other) }
    }

    /// 每完成几个专注安排一次长休息。
    @Published var pomodoroLongBreakEvery: Int {
        didSet { persist(pomodoroLongBreakEvery, forKey: Keys.pomodoroLongBreakEvery, change: .other) }
    }

    @Published var pomodoroAutoStartBreak: Bool {
        didSet { persist(pomodoroAutoStartBreak, forKey: Keys.pomodoroAutoStartBreak, change: .other) }
    }

    @Published var pomodoroAutoStartFocus: Bool {
        didSet { persist(pomodoroAutoStartFocus, forKey: Keys.pomodoroAutoStartFocus, change: .other) }
    }

    @Published var pomodoroShowsInMenuBar: Bool {
        didSet { persist(pomodoroShowsInMenuBar, forKey: Keys.pomodoroShowsInMenuBar, change: .other) }
    }

    var onChange: ((SettingsChange) -> Void)?

    private let defaults: UserDefaults
    private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        waterEnabled = defaults.object(forKey: Keys.waterEnabled) as? Bool ?? true
        waterIntervalMinutes = defaults.object(forKey: Keys.waterIntervalMinutes) as? Int ?? 45
        eyeEnabled = defaults.object(forKey: Keys.eyeEnabled) as? Bool ?? true
        eyeIntervalMinutes = defaults.object(forKey: Keys.eyeIntervalMinutes) as? Int ?? 30
        eyeRestDurationSeconds = defaults.object(forKey: Keys.eyeRestDurationSeconds) as? Int ?? 20
        standEnabled = defaults.object(forKey: Keys.standEnabled) as? Bool ?? true
        standIntervalMinutes = defaults.object(forKey: Keys.standIntervalMinutes) as? Int ?? 50
        lockResetThresholdMinutes = defaults.object(forKey: Keys.lockResetThresholdMinutes) as? Int ?? 2
        autoDismissHealthToasts = defaults.object(forKey: Keys.autoDismissHealthToasts) as? Bool ?? false
        lockScreenAfterStanding = defaults.object(forKey: Keys.lockScreenAfterStanding) as? Bool ?? false
        pomodoroFocusMinutes = defaults.object(forKey: Keys.pomodoroFocusMinutes) as? Int ?? 25
        pomodoroShortBreakMinutes = defaults.object(forKey: Keys.pomodoroShortBreakMinutes) as? Int ?? 5
        pomodoroLongBreakMinutes = defaults.object(forKey: Keys.pomodoroLongBreakMinutes) as? Int ?? 15
        pomodoroLongBreakEvery = defaults.object(forKey: Keys.pomodoroLongBreakEvery) as? Int ?? 4
        pomodoroAutoStartBreak = defaults.object(forKey: Keys.pomodoroAutoStartBreak) as? Bool ?? true
        pomodoroAutoStartFocus = defaults.object(forKey: Keys.pomodoroAutoStartFocus) as? Bool ?? false
        pomodoroShowsInMenuBar = defaults.object(forKey: Keys.pomodoroShowsInMenuBar) as? Bool ?? true
        isLoading = false
    }

    func isEnabled(_ type: ReminderType) -> Bool {
        switch type {
        case .water: waterEnabled
        case .eyeRest: eyeEnabled
        case .stand: standEnabled
        }
    }

    func intervalMinutes(for type: ReminderType) -> Int {
        switch type {
        case .water: waterIntervalMinutes
        case .eyeRest: eyeIntervalMinutes
        case .stand: standIntervalMinutes
        }
    }

    private func persist(_ value: Any, forKey key: String, change: SettingsChange) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
        onChange?(change)
    }

    private enum Keys {
        static let waterEnabled = "waterEnabled"
        static let waterIntervalMinutes = "waterIntervalMinutes"
        static let eyeEnabled = "eyeEnabled"
        static let eyeIntervalMinutes = "eyeIntervalMinutes"
        static let eyeRestDurationSeconds = "eyeRestDurationSeconds"
        static let standEnabled = "standEnabled"
        static let standIntervalMinutes = "standIntervalMinutes"
        static let lockResetThresholdMinutes = "lockResetThresholdMinutes"
        static let autoDismissHealthToasts = "autoDismissHealthToasts"
        static let lockScreenAfterStanding = "lockScreenAfterStanding"
        static let pomodoroFocusMinutes = "pomodoroFocusMinutes"
        static let pomodoroShortBreakMinutes = "pomodoroShortBreakMinutes"
        static let pomodoroLongBreakMinutes = "pomodoroLongBreakMinutes"
        static let pomodoroLongBreakEvery = "pomodoroLongBreakEvery"
        static let pomodoroAutoStartBreak = "pomodoroAutoStartBreak"
        static let pomodoroAutoStartFocus = "pomodoroAutoStartFocus"
        static let pomodoroShowsInMenuBar = "pomodoroShowsInMenuBar"
    }
}
