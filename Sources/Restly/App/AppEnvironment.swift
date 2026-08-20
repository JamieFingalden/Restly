import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let settings: ReminderSettings
    let reminderManager: ReminderManager
    let launchAtLoginManager: LaunchAtLoginManager
    let settingsWindowController: SettingsWindowController
    private var menuPreviewWindowController: MenuPreviewWindowController?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let settings = ReminderSettings()
        let activityMonitor = ActivityMonitor()
        let toastManager = ToastManager()
        let overlayController = EyeRestOverlayController()

        let reminderManager = ReminderManager(
            settings: settings,
            activityMonitor: activityMonitor,
            toastManager: toastManager,
            overlayController: overlayController
        )
        let launchAtLoginManager = LaunchAtLoginManager()
        let settingsWindowController = SettingsWindowController(
            settings: settings,
            manager: reminderManager,
            launchAtLoginManager: launchAtLoginManager
        )

        self.settings = settings
        self.reminderManager = reminderManager
        self.launchAtLoginManager = launchAtLoginManager
        self.settingsWindowController = settingsWindowController

        if arguments.contains("--show-settings") {
            settingsWindowController.perform(#selector(SettingsWindowController.show), with: nil, afterDelay: 1)
        }
        if arguments.contains("--show-menu-preview") {
            let preview = MenuPreviewWindowController(
                manager: reminderManager,
                settingsWindowController: settingsWindowController
            )
            menuPreviewWindowController = preview
            preview.perform(#selector(MenuPreviewWindowController.show), with: nil, afterDelay: 1)
        }
        if arguments.contains("--show-water-preview") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                toastManager.show(.water, intervalMinutes: settings.waterIntervalMinutes)
            }
        }
        if arguments.contains("--show-stand-preview") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                toastManager.show(.stand, intervalMinutes: settings.standIntervalMinutes)
            }
        }
    }
}
