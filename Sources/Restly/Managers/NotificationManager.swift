import AppKit
import SwiftUI

@MainActor
final class NotificationManager: NSObject {
    var actionHandler: ((ReminderType, ReminderAction) -> Void)?

    private let panelSize = NSSize(width: 420, height: 136)
    private var panels: [ReminderType: RestlyReminderPanel] = [:]
    private var displayOrder: [ReminderType] = []

    func send(_ type: ReminderType, standIntervalMinutes: Int? = nil) {
        dismiss(type, action: nil)

        let panel = makePanel(
            for: type,
            standIntervalMinutes: standIntervalMinutes
        )
        panels[type] = panel
        displayOrder.append(type)
        repositionPanels(animated: false)

        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + 14))
        panel.orderFrontRegardless()

        let finalFrame = frame(for: type)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }

        playReminderSound()
    }

    private func makePanel(
        for type: ReminderType,
        standIntervalMinutes: Int?
    ) -> RestlyReminderPanel {
        let panel = RestlyReminderPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(
            rootView: ReminderBannerView(
                type: type,
                standIntervalMinutes: standIntervalMinutes,
                onCompleted: { [weak self] in
                    self?.dismiss(type, action: .completed)
                },
                onSnoozed: { [weak self] in
                    self?.dismiss(type, action: .snoozed)
                },
                onDismissed: { [weak self] in
                    self?.dismiss(type, action: .skipped)
                }
            )
        )
        return panel
    }

    private func dismiss(_ type: ReminderType, action: ReminderAction?) {
        guard let panel = panels.removeValue(forKey: type) else { return }
        displayOrder.removeAll { $0 == type }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })

        repositionPanels(animated: true)
        if let action {
            actionHandler?(type, action)
        }
    }

    private func repositionPanels(animated: Bool) {
        for type in displayOrder.reversed() {
            guard let panel = panels[type] else { continue }
            let targetFrame = frame(for: type)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(targetFrame, display: true)
                }
            } else {
                panel.setFrame(targetFrame, display: true)
            }
        }
    }

    private func frame(for type: ReminderType) -> NSRect {
        let screen = activeScreen()
        let visibleFrame = screen.visibleFrame
        let reversedOrder = Array(displayOrder.reversed())
        let index = reversedOrder.firstIndex(of: type) ?? 0
        let spacing: CGFloat = 10
        let origin = NSPoint(
            x: visibleFrame.maxX - panelSize.width - 18,
            y: visibleFrame.maxY - panelSize.height - 14 - CGFloat(index) * (panelSize.height + spacing)
        )
        return NSRect(origin: origin, size: panelSize)
    }

    private func activeScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func playReminderSound() {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

private final class RestlyReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ReminderBannerView: View {
    let type: ReminderType
    let standIntervalMinutes: Int?
    let onCompleted: () -> Void
    let onSnoozed: () -> Void
    let onDismissed: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            RestlyBrandMark(size: 58)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: type.systemImage)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(accentColor)

                    Text(title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))

                    Spacer(minLength: 6)

                    Button(action: onDismissed) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("关闭提醒")
                }

                Text(message)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    Button(primaryActionTitle, action: onCompleted)
                        .buttonStyle(.borderedProminent)
                        .tint(accentColor)
                        .controlSize(.regular)

                    Button("10 分钟后提醒", action: onSnoozed)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }
        }
        .padding(18)
        .frame(width: 420, height: 136)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.16), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.42), accentColor.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
    }

    private var title: String {
        switch type {
        case .water: "该喝水了"
        case .eyeRest: "让眼睛休息一下"
        case .stand: "起来活动一下"
        }
    }

    private var message: String {
        switch type {
        case .water:
            "喝一杯水，让身体保持舒适。"
        case .eyeRest:
            "闭上眼睛，或者看看远处。"
        case .stand:
            if let standIntervalMinutes {
                "你已经连续使用电脑 \(standIntervalMinutes) 分钟，起来走走吧。"
            } else {
                "你已经连续使用电脑一段时间，起来走走吧。"
            }
        }
    }

    private var primaryActionTitle: String {
        switch type {
        case .water: "已喝水"
        case .eyeRest: "完成"
        case .stand: "我起来了"
        }
    }

    private var accentColor: Color {
        switch type {
        case .water: Color(red: 0.08, green: 0.74, blue: 0.72)
        case .eyeRest: .cyan
        case .stand: Color(red: 0.14, green: 0.52, blue: 0.96)
        }
    }
}
