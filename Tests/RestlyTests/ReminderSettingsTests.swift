import XCTest
@testable import Restly

final class ReminderSettingsTests: XCTestCase {
    @MainActor
    func testHealthToastAndScreenLockDefaultsPersistUserChoices() {
        let suiteName = "ReminderSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialSettings = ReminderSettings(defaults: defaults)
        XCTAssertFalse(initialSettings.autoDismissHealthToasts)
        XCTAssertFalse(initialSettings.lockScreenAfterStanding)

        initialSettings.autoDismissHealthToasts = true
        initialSettings.lockScreenAfterStanding = true
        let reloadedSettings = ReminderSettings(defaults: defaults)
        XCTAssertTrue(reloadedSettings.autoDismissHealthToasts)
        XCTAssertTrue(reloadedSettings.lockScreenAfterStanding)
    }
}
