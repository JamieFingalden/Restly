import AppKit
import SwiftUI

/// 菜单栏的原生菜单内容（macOS 官方 NSMenu 样式，`.menuBarExtraStyle(.menu)`）。
/// ⚠️ 只用标准构造：Button / Divider / Section(标题) / Menu。曾经把 `Text`
/// 直接当菜单项用，结果渲染高度和 NSMenu 条目槽位对不齐，命中测试整体
/// 上移一行（鼠标在「暂停」却高亮「短休息」）—— 非标准内容会破坏对齐。
/// 纯信息行用 `Button(...).disabled(true)` 占标准槽位；番茄钟的阶段和
/// 倒计时做成分节标题，操作项就是它的内容。倒计时文字是构建菜单那一刻
/// 的快照，重新打开菜单就会拿到新值；实时跳动在菜单栏图标旁。
struct MenuBarView: View {
    @ObservedObject var manager: ReminderManager
    @ObservedObject var pomodoroManager: PomodoroManager
    let settingsWindowController: SettingsWindowController

    var body: some View {
        Button(statusLine) {}
            .disabled(true)

        Divider()

        pomodoroSection

        Divider()

        Section("提醒") {
            ForEach(ReminderType.allCases) { type in
                Button("\(type.title) · \(manager.remainingDescription(for: type))") {}
                    .disabled(true)
            }
        }

        Divider()

        pauseMenu
        Button("设置…") {
            settingsWindowController.show()
        }
        Divider()
        Button("退出 Restly") {
            NSApp.terminate(nil)
        }
    }

    // MARK: - 状态

    private var statusLine: String {
        if manager.isPaused() { return "提醒已暂停" }
        if !manager.isScreenAvailable { return "提醒已停止" }
        return "提醒计时中"
    }

    // MARK: - 番茄钟

    /// 阶段 + 倒计时做分节标题，操作做条目 —— 状态和动作天然归在一组。
    @ViewBuilder
    private var pomodoroSection: some View {
        switch pomodoroManager.session.status {
        case nil:
            Section("番茄钟 · \(pomodoroManager.focusSummaryText)") {
                Button("开始专注") {
                    pomodoroManager.startFocus()
                }
            }
        case .running:
            Section("\(activeTitle) · \(pomodoroManager.countdownText(at: Date()) ?? "0:00")") {
                Button("暂停") {
                    pomodoroManager.pause()
                }
                Button("跳过\(phaseTitle)") {
                    pomodoroManager.skip()
                }
                Button("停止番茄钟") {
                    pomodoroManager.stop()
                }
            }
        case .paused:
            Section("\(activeTitle) · 已暂停 · \(pomodoroManager.countdownText(at: Date()) ?? "0:00")") {
                Button("继续") {
                    pomodoroManager.resume()
                }
                Button("跳过\(phaseTitle)") {
                    pomodoroManager.skip()
                }
                Button("停止番茄钟") {
                    pomodoroManager.stop()
                }
            }
        case .awaitingStart:
            Section("下一阶段 · \(phaseTitle)") {
                Button("开始\(phaseTitle)") {
                    pomodoroManager.startPendingPhase()
                }
                Button("跳过") {
                    pomodoroManager.skip()
                }
            }
        }
    }

    private var activeTitle: String {
        switch pomodoroManager.session.phase {
        case .focus: "专注"
        case .shortBreak: "短休息"
        case .longBreak: "长休息"
        case nil: "番茄钟"
        }
    }

    private var phaseTitle: String {
        pomodoroManager.session.phase?.title ?? ""
    }

    // MARK: - 暂停提醒

    private var pauseMenu: some View {
        Menu(manager.isPaused() ? "已暂停" : "暂停提醒") {
            if manager.isPaused() {
                Button("恢复提醒") {
                    manager.resume()
                }
                Divider()
            }
            Button("暂停 30 分钟") {
                manager.pause(for: 30)
            }
            Button("暂停 1 小时") {
                manager.pause(for: 60)
            }
            Button("暂停 2 小时") {
                manager.pause(for: 120)
            }
            Divider()
            Button("暂停到我手动恢复") {
                manager.pauseIndefinitely()
            }
        }
    }
}
