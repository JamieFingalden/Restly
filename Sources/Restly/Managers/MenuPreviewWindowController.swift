import AppKit
import SwiftUI

@MainActor
final class MenuPreviewWindowController: NSObject {
    private let manager: ReminderManager
    private let pomodoroManager: PomodoroManager
    private let settingsWindowController: SettingsWindowController
    private var windowController: NSWindowController?

    init(
        manager: ReminderManager,
        pomodoroManager: PomodoroManager,
        settingsWindowController: SettingsWindowController
    ) {
        self.manager = manager
        self.pomodoroManager = pomodoroManager
        self.settingsWindowController = settingsWindowController
    }

    @objc func show() {
        // 菜单换成了原生 NSMenu 内容，预览窗只作条目排布参考，
        // 真实样式以 --open-menu 打开的系统菜单为准。
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = NSHostingView(
            rootView: MenuBarView(
                manager: manager,
                pomodoroManager: pomodoroManager,
                settingsWindowController: settingsWindowController
            )
        )

        let windowController = NSWindowController(window: panel)
        self.windowController = windowController
        windowController.showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
