import AppKit
import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let settings: ReminderSettings
    let reminderManager: ReminderManager
    let pomodoroManager: PomodoroManager
    let launchAtLoginManager: LaunchAtLoginManager
    let settingsWindowController: SettingsWindowController
    private var menuPreviewWindowController: MenuPreviewWindowController?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let settings = ReminderSettings()
        let screenStateMonitor = ScreenStateMonitor()
        let toastManager = ToastManager()
        let overlayController = EyeRestOverlayController()
        let screenLockManager = ScreenLockManager()

        let reminderManager = ReminderManager(
            settings: settings,
            toastManager: toastManager,
            overlayController: overlayController,
            screenLockManager: screenLockManager
        )
        let focusModeBridge = FocusModeBridge()
        let pomodoroManager = PomodoroManager(
            settings: settings,
            toastManager: toastManager,
            focusModeBridge: focusModeBridge
        )

        // ScreenStateMonitor 的回调是一次性闭包属性，订阅者不止一个之后
        // 在组合根统一接线、fan-out 给两个 manager。
        screenStateMonitor.onUnavailable = { [weak reminderManager, weak pomodoroManager] in
            reminderManager?.handleScreenUnavailable()
            pomodoroManager?.screenDidBecomeUnavailable()
        }
        screenStateMonitor.onAvailable = { [weak reminderManager, weak pomodoroManager] lockedDuration in
            reminderManager?.handleScreenAvailable(after: lockedDuration)
            pomodoroManager?.screenDidBecomeAvailable(after: lockedDuration)
        }
        screenStateMonitor.start()

        let launchAtLoginManager = LaunchAtLoginManager()
        let settingsWindowController = SettingsWindowController(
            settings: settings,
            manager: reminderManager,
            launchAtLoginManager: launchAtLoginManager,
            focusModeBridge: focusModeBridge
        )
        // 联动失效 Toast 的「重新创建」把设置窗口带上来。
        pomodoroManager.onRequestOpenSettings = { [weak settingsWindowController] in
            settingsWindowController?.show()
        }

        self.settings = settings
        self.reminderManager = reminderManager
        self.pomodoroManager = pomodoroManager
        self.launchAtLoginManager = launchAtLoginManager
        self.settingsWindowController = settingsWindowController

        if arguments.contains("--show-settings") {
            settingsWindowController.perform(#selector(SettingsWindowController.show), with: nil, afterDelay: 1)
        }
        if arguments.contains("--show-menu-preview") {
            let preview = MenuPreviewWindowController(
                manager: reminderManager,
                pomodoroManager: pomodoroManager,
                settingsWindowController: settingsWindowController
            )
            menuPreviewWindowController = preview
            preview.perform(#selector(MenuPreviewWindowController.show), with: nil, afterDelay: 1)
        }
        if arguments.contains("--show-water-preview") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                toastManager.show(
                    .water,
                    intervalMinutes: settings.waterIntervalMinutes,
                    autoDismiss: settings.autoDismissHealthToasts
                )
            }
        }
        if arguments.contains("--show-stand-preview") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                toastManager.show(
                    .stand,
                    intervalMinutes: settings.standIntervalMinutes,
                    autoDismiss: settings.autoDismissHealthToasts
                )
            }
        }
        if arguments.contains("--show-pomodoro-preview") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                toastManager.showPomodoroToast(PomodoroToastRequest(
                    title: "专注完成",
                    subtitle: "休息一下，短休息 5 分钟",
                    systemImage: PomodoroSession.Phase.shortBreak.systemImage,
                    primaryTitle: "开始短休息",
                    primaryAction: {},
                    secondaryTitle: "跳过休息",
                    secondaryAction: {}
                ))
            }
        }
        if arguments.contains("--open-menu") {
            // 打开真实的菜单栏菜单用于调试/截图 —— 状态项注册有快有慢，多点几次。
            Task { @MainActor in
                for _ in 0..<8 {
                    try? await Task.sleep(for: .seconds(0.5))
                    if Self.clickMenuBarStatusItem() { break }
                }
            }
        }
    }

    /// 点开自家菜单栏菜单。老的 statusItems KVC 在新系统上已经取不到了，
    /// 改从自家窗口树里找：真正的状态栏窗口在屏幕内，占位窗口都堆在
    /// 屏幕外的 (0, -39)，按钮是窗口内容视图里的 NSStatusBarButton。
    @discardableResult
    private static func clickMenuBarStatusItem() -> Bool {
        let window = NSApp.windows.first {
            $0.className == "NSStatusBarWindow" && $0.frame.minY > 0
        }
        guard let button = window.flatMap({ statusBarButton(in: $0.contentView) }) else {
            return false
        }
        button.performClick(nil)
        return true
    }

    private static func statusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusBarButton(in: subview) { return button }
        }
        return nil
    }
}
