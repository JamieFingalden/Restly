import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject {
    private let settings: ReminderSettings
    private let manager: ReminderManager
    private let launchAtLoginManager: LaunchAtLoginManager
    private var windowController: NSWindowController?

    init(
        settings: ReminderSettings,
        manager: ReminderManager,
        launchAtLoginManager: LaunchAtLoginManager
    ) {
        self.settings = settings
        self.manager = manager
        self.launchAtLoginManager = launchAtLoginManager
    }

    @objc func show() {
        if let windowController {
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Restly 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsView(
                settings: settings,
                manager: manager,
                launchAtLoginManager: launchAtLoginManager
            )
        )

        let windowController = NSWindowController(window: window)
        self.windowController = windowController
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
