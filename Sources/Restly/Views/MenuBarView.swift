import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: ReminderManager
    let settingsWindowController: SettingsWindowController

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 12) {
                    menuContent
                }
            } else {
                menuContent
            }
        }
        .padding(16)
        .frame(width: 330)
        .restlyWindowGlass(cornerRadius: 22)
        .onAppear {
            manager.refreshActivityStatus()
            makeMenuWindowTransparent()
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let pauseDescription = manager.pauseDescription() {
                Label(pauseDescription, systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }

            reminderList

            Divider().opacity(0.45)

            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RestlyBrandMark(size: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("Restly")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("休息得刚刚好")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            activityBadge
        }
    }

    private var activityBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(activityColor)
                .frame(width: 6, height: 6)
            Text(manager.activityState.description)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(activityColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .restlyClearGlassSurface(cornerRadius: 20, tint: activityColor.opacity(0.16))
        .accessibilityElement(children: .combine)
    }

    private var reminderList: some View {
        VStack(spacing: 0) {
            ForEach(Array(ReminderType.allCases.enumerated()), id: \.element.id) { index, type in
                ReminderRow(
                    type: type,
                    remaining: manager.remainingDescription(for: type)
                )
                if index < ReminderType.allCases.count - 1 {
                    Divider()
                        .padding(.leading, 52)
                }
            }
        }
        .padding(4)
        .restlyClearGlassSurface(cornerRadius: 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            pauseMenu
            Spacer()
            Button {
                let menuWindow = NSApp.keyWindow
                dismiss()
                menuWindow?.orderOut(nil)
                settingsWindowController.perform(
                    #selector(SettingsWindowController.show),
                    with: nil,
                    afterDelay: 0.08
                )
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("退出 Restly")
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .controlSize(.small)
        .restlyGlassButtonStyle()
    }

    private var pauseMenu: some View {
        Menu {
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
        } label: {
            Label(manager.isPaused() ? "已暂停" : "暂停提醒", systemImage: "pause.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .restlyGlassButtonStyle()
    }

    private func makeMenuWindowTransparent() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }

    private var activityColor: Color {
        switch manager.activityState {
        case .active: Color(red: 0.12, green: 0.62, blue: 0.43)
        case .idle: Color(red: 0.9, green: 0.56, blue: 0.12)
        case .away, .sleeping: .secondary
        }
    }
}
