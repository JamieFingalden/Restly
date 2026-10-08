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
                pomodoroManager: environment.pomodoroManager,
                settingsWindowController: environment.settingsWindowController
            )
        } label: {
            MenuBarLabel(
                reminderManager: environment.reminderManager,
                pomodoroManager: environment.pomodoroManager
            )
        }
        // 官方原生菜单：圆角、材质、行为全交给系统。之前自绘的玻璃面板
        // 在 macOS 26/27 上反复出渲染问题，不值得再修。
        .menuBarExtraStyle(.menu)
    }
}

/// 菜单栏图标。健康提醒暂停时换成划掉的心形 ——
/// 无限期暂停要是没有视觉提示，用户忘了恢复就会以为程序坏了。
/// 番茄钟计时中在旁边多挂一个倒计时（专注 🍅、休息 ☕，由
/// PomodoroManager 拼进文本），扫一眼菜单栏就知道还剩多久。
/// ⚠️ 这里不能用 TimelineView：macOS 27 上它会反复重栅格化状态栏
/// 图片并无限触发失效更新（主线程卡死 + 内存狂飙）。倒计时文本由
/// PomodoroManager 的秒级 Timer 更新，本视图纯展示。
private struct MenuBarLabel: View {
    @ObservedObject var reminderManager: ReminderManager
    @ObservedObject var pomodoroManager: PomodoroManager

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: reminderManager.isPaused() ? "heart.slash" : "heart.fill")

            if pomodoroManager.showsInMenuBar {
                pomodoroStatus
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var pomodoroStatus: some View {
        switch pomodoroManager.menuBarStatus {
        case .running(let text):
            Text(text)
                .monospacedDigit()
        case .paused(let text):
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let icon = RestlyAppIcon.image else {
            NSLog("Restly 无法加载应用图标。")
            return
        }
        NSApp.applicationIconImage = icon
    }
}
