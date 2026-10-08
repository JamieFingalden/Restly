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

        settings.pomodoroFocusMinutes = 50
        settings.pomodoroShortBreakMinutes = 10
        settings.pomodoroLongBreakMinutes = 30
        settings.pomodoroLongBreakEvery = 2
        settings.pomodoroAutoStartBreak = false
        settings.pomodoroAutoStartFocus = true
        settings.pomodoroShowsInMenuBar = false

        let reloaded = ReminderSettings(defaults: defaults)
        XCTAssertEqual(reloaded.pomodoroFocusMinutes, 50)
        XCTAssertEqual(reloaded.pomodoroShortBreakMinutes, 10)
        XCTAssertEqual(reloaded.pomodoroLongBreakMinutes, 30)
        XCTAssertEqual(reloaded.pomodoroLongBreakEvery, 2)
        XCTAssertFalse(reloaded.pomodoroAutoStartBreak)
        XCTAssertTrue(reloaded.pomodoroAutoStartFocus)
        XCTAssertFalse(reloaded.pomodoroShowsInMenuBar)
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

        XCTAssertEqual(changes, Array(repeating: .other, count: 7))
    }
}
