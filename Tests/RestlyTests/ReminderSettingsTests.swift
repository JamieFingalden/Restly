import XCTest
@testable import Restly

final class ReminderSettingsTests: XCTestCase {
    @MainActor
    private func makeSettings() -> (ReminderSettings, String, UserDefaults) {
        let suiteName = "ReminderSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (ReminderSettings(defaults: defaults), suiteName, defaults)
    }

    @MainActor
    func testHealthToastAndScreenLockDefaultsPersistUserChoices() {
        let (settings, suiteName, defaults) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(settings.autoDismissHealthToasts)
        XCTAssertFalse(settings.lockScreenAfterStanding)
        XCTAssertEqual(settings.lockResetThresholdMinutes, 2)

        settings.autoDismissHealthToasts = true
        settings.lockScreenAfterStanding = true
        settings.lockResetThresholdMinutes = 5

        let reloaded = ReminderSettings(defaults: defaults)
        XCTAssertTrue(reloaded.autoDismissHealthToasts)
        XCTAssertTrue(reloaded.lockScreenAfterStanding)
        XCTAssertEqual(reloaded.lockResetThresholdMinutes, 5)
    }

    /// 这条测的是那个「改任何设置都清空所有计时」的 bug：
    /// 只有间隔和开关会带上具体的提醒类型，其余设置一律是 .other，不碰计时。
    @MainActor
    func testOnlyIntervalAndEnabledChangesCarryAReminderType() {
        let (settings, suiteName, defaults) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var changes: [SettingsChange] = []
        settings.onChange = { changes.append($0) }

        settings.waterIntervalMinutes = 50
        settings.eyeEnabled = false
        settings.autoDismissHealthToasts = true
        settings.eyeRestDurationSeconds = 30
        settings.lockResetThresholdMinutes = 5
        settings.lockScreenAfterStanding = true

        XCTAssertEqual(
            changes,
            [
                .interval(.water),
                .enabled(.eyeRest),
                .other,
                .other,
                .other,
                .other
            ]
        )
    }

    @MainActor
    func testLoadingFromDefaultsDoesNotEmitChanges() {
        let (settings, suiteName, defaults) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        settings.waterIntervalMinutes = 50

        var changes: [SettingsChange] = []
        let reloaded = ReminderSettings(defaults: defaults)
        reloaded.onChange = { changes.append($0) }

        XCTAssertEqual(reloaded.waterIntervalMinutes, 50)
        XCTAssertTrue(changes.isEmpty)
    }

    @MainActor
    func testPomodoroDefaultsRoundTripThroughDefaults() {
        let (settings, suiteName, defaults) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 出厂默认：经典番茄钟节奏，休息后回专注要手动确认。
        XCTAssertEqual(settings.pomodoroFocusMinutes, 25)
        XCTAssertEqual(settings.pomodoroShortBreakMinutes, 5)
        XCTAssertEqual(settings.pomodoroLongBreakMinutes, 15)
        XCTAssertEqual(settings.pomodoroLongBreakEvery, 4)
        XCTAssertTrue(settings.pomodoroAutoStartBreak)
        XCTAssertFalse(settings.pomodoroAutoStartFocus)
        XCTAssertTrue(settings.pomodoroShowsInMenuBar)
        // 专注模式联动依赖用户自建的快捷指令，出厂必须关着。
        XCTAssertFalse(settings.pomodoroLinksFocusMode)

        settings.pomodoroFocusMinutes = 50
        settings.pomodoroShortBreakMinutes = 10
        settings.pomodoroLongBreakMinutes = 30
        settings.pomodoroLongBreakEvery = 2
        settings.pomodoroAutoStartBreak = false
        settings.pomodoroAutoStartFocus = true
        settings.pomodoroShowsInMenuBar = false
        settings.pomodoroLinksFocusMode = true

        let reloaded = ReminderSettings(defaults: defaults)
        XCTAssertEqual(reloaded.pomodoroFocusMinutes, 50)
        XCTAssertEqual(reloaded.pomodoroShortBreakMinutes, 10)
        XCTAssertEqual(reloaded.pomodoroLongBreakMinutes, 30)
        XCTAssertEqual(reloaded.pomodoroLongBreakEvery, 2)
        XCTAssertFalse(reloaded.pomodoroAutoStartBreak)
        XCTAssertTrue(reloaded.pomodoroAutoStartFocus)
        XCTAssertFalse(reloaded.pomodoroShowsInMenuBar)
        XCTAssertTrue(reloaded.pomodoroLinksFocusMode)
    }

    /// 番茄钟的设置一律 .other：它们和健康提醒的计时无关，
    /// 不该触发 ReminderManager 里任何针对提醒类型的重置。
    @MainActor
    func testAllPomodoroSettingChangesAreOther() {
        let (settings, suiteName, defaults) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var changes: [SettingsChange] = []
        settings.onChange = { changes.append($0) }

        settings.pomodoroFocusMinutes = 30
        settings.pomodoroShortBreakMinutes = 10
        settings.pomodoroLongBreakMinutes = 20
        settings.pomodoroLongBreakEvery = 3
        settings.pomodoroAutoStartBreak = false
        settings.pomodoroAutoStartFocus = true
        settings.pomodoroShowsInMenuBar = false
        settings.pomodoroLinksFocusMode = true
        settings.focusLinkOnShortcutName = "设定专注模式"
        settings.focusLinkOffShortcutName = "关闭专注模式"

        XCTAssertEqual(changes, Array(repeating: .other, count: 10))
    }

    /// 联动指令名字：出厂默认两条常量名，用户指认后持久化；
    /// 清空/纯空白回退默认 —— 输入框清空不该让联动去找空名字。
    @MainActor
    func testFocusLinkShortcutNamesDefaultPersistAndFallBack() {
        let (settings, suiteName, defaults) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(settings.focusLinkOnShortcutName, FocusModeBridge.defaultOnShortcutName)
        XCTAssertEqual(settings.focusLinkOffShortcutName, FocusModeBridge.defaultOffShortcutName)
        XCTAssertEqual(settings.resolvedFocusLinkOnName, FocusModeBridge.defaultOnShortcutName)
        XCTAssertEqual(settings.resolvedFocusLinkOffName, FocusModeBridge.defaultOffShortcutName)

        settings.focusLinkOnShortcutName = "  设定专注模式  "
        settings.focusLinkOffShortcutName = "关闭专注模式"

        let reloaded = ReminderSettings(defaults: defaults)
        XCTAssertEqual(reloaded.resolvedFocusLinkOnName, "设定专注模式")
        XCTAssertEqual(reloaded.resolvedFocusLinkOffName, "关闭专注模式")

        reloaded.focusLinkOnShortcutName = "   "
        XCTAssertEqual(reloaded.resolvedFocusLinkOnName, FocusModeBridge.defaultOnShortcutName)
    }

    /// 联动开关的翻转走独立回调（PomodoroManager 靠它立刻执行
    /// 开启/关闭），读档初始化不算翻转、不触发。
    @MainActor
    func testLinksFocusModeChangeNotifiesCallbackButNotDuringLoad() {
        let suiteName = "ReminderSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 存档里已开启：初始化读档不应触发翻转回调。
        defaults.set(true, forKey: "pomodoroLinksFocusMode")
        let settings = ReminderSettings(defaults: defaults)

        var notifications = 0
        settings.onLinksFocusModeChange = { notifications += 1 }

        XCTAssertEqual(settings.pomodoroLinksFocusMode, true)
        XCTAssertEqual(notifications, 0, "初始化读档不算翻转")

        settings.pomodoroLinksFocusMode = false
        XCTAssertEqual(notifications, 1)
    }
}
