import AppKit
import SwiftUI

@MainActor
@main
struct RestlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                manager: environment.reminderManager,
                settingsWindowController: environment.settingsWindowController
            )
        } label: {
            Image(systemName: "heart.fill")
                .accessibilityLabel("Restly")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let iconURL = Bundle.main.url(forResource: "RestlyIcon", withExtension: "png"),
              let icon = NSImage(contentsOf: iconURL) else {
            NSLog("Restly 无法加载应用图标。")
            return
        }
        NSApp.applicationIconImage = icon
    }
}
