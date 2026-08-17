import AppKit
import SwiftUI

@MainActor
final class MenuPreviewWindowController: NSObject {
    private let manager: ReminderManager
    private let settingsWindowController: SettingsWindowController
    private var windowController: NSWindowController?

    init(manager: ReminderManager, settingsWindowController: SettingsWindowController) {
        self.manager = manager
        self.settingsWindowController = settingsWindowController
    }

    @objc func show() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 308),
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
