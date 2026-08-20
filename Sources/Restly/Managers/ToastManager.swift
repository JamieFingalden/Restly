import AppKit
import SwiftUI

@MainActor
final class ToastManager: NSObject {
    var actionHandler: ((ReminderType, ReminderAction) -> Void)?

    // macOS 菜单栏底边与 Toast 之间的额外距离，需要实机微调时只改这里。
    static let topSafeArea: CGFloat = 20

    private let panelSize = NSSize(width: 324, height: 68)
    private let displayDuration: Duration = .seconds(8)
    private let queueDelay: Duration = .milliseconds(1300)
    private var queue = HealthToastQueue()
    private var activeToast: HealthToast?
    private var activePanel: HealthToastPanel?
    private var presentation: ToastPresentationState?
    private var autoDismissTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var isDismissing = false

    func show(_ type: ReminderType, intervalMinutes: Int) {
        guard let toastType = HealthToastType(reminderType: type) else { return }
        guard activeToast?.type != toastType else { return }

        let toast = HealthToast(type: toastType, intervalMinutes: intervalMinutes)
        guard queue.enqueue(toast) else { return }
        presentNextIfPossible()
    }

    private func presentNextIfPossible() {
        guard activeToast == nil,
              let screen = activeScreen(),
              let toast = queue.dequeue() else {
            return
        }

        let presentation = ToastPresentationState()
        let panel = makePanel(toast: toast, presentation: presentation)
        panel.setFrame(frame(on: screen), display: true)

        activeToast = toast
        activePanel = panel
        self.presentation = presentation
        isDismissing = false

        // nonactivatingPanel + orderFrontRegardless 只展示，不改变当前键盘焦点。
        panel.orderFrontRegardless()
        presentation.show()
        playReminderSound()

        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: self?.displayDuration ?? .seconds(8))
            guard !Task.isCancelled else { return }
            self?.dismissActive(action: nil)
        }
    }

    private func makePanel(
        toast: HealthToast,
        presentation: ToastPresentationState
    ) -> HealthToastPanel {
        let panel = HealthToastPanel(
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
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]

        let hostingView = NSHostingView(
            rootView: HealthToastView(
                toast: toast,
                presentation: presentation,
                onCompleted: { [weak self] in
                    self?.dismissActive(action: .completed)
                },
                onSnoozed: { [weak self] in
                    self?.dismissActive(action: .snoozed)
                }
            )
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        return panel
    }

    private func dismissActive(action: ReminderAction?) {
        guard !isDismissing,
              let toast = activeToast,
              let panel = activePanel else {
            return
        }

        isDismissing = true
        autoDismissTask?.cancel()
        autoDismissTask = nil
        presentation?.hide()

        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }

            panel.orderOut(nil)
            panel.close()
            self?.activePanel = nil
            self?.presentation = nil
            self?.activeToast = nil
            self?.isDismissing = false

            if let action {
                self?.actionHandler?(toast.type.reminderType, action)
            }

            try? await Task.sleep(for: self?.queueDelay ?? .milliseconds(1300))
            guard !Task.isCancelled else { return }
            self?.presentNextIfPossible()
        }
    }

    private func frame(on screen: NSScreen) -> NSRect {
        HealthToastLayout.frame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            toastSize: panelSize,
            topSafeArea: Self.topSafeArea
        )
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func playReminderSound() {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

@MainActor
private final class ToastPresentationState: ObservableObject {
    @Published private(set) var isVisible = false

    func show() {
        isVisible = true
    }

    func hide() {
        isVisible = false
    }
}

private final class HealthToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct HealthToastView: View {
    let toast: HealthToast
    @ObservedObject var presentation: ToastPresentationState
    let onCompleted: () -> Void
    let onSnoozed: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.16))
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(accentColor)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(toast.type.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(toast.durationText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 12) {
                    Button(toast.type.primaryActionTitle, action: onCompleted)
                        .foregroundStyle(accentColor)
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 1, height: 11)
                    Button("10 分钟后", action: onSnoozed)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 324, height: 68)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(accentColor.opacity(0.06))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 0.7)
        }
        .opacity(presentation.isVisible ? 1 : 0)
        .scaleEffect(presentation.isVisible ? 1 : 0.97)
        .offset(y: presentation.isVisible ? 0 : -8)
        .animation(
            .spring(response: 0.32, dampingFraction: 0.9),
            value: presentation.isVisible
        )
        .accessibilityElement(children: .contain)
    }

    private var systemImage: String {
        switch toast.type {
        case .water: "drop.fill"
        case .stand: "figure.stand"
        }
    }

    private var accentColor: Color {
        switch toast.type {
        case .water: Color(red: 0.08, green: 0.7, blue: 0.72)
        case .stand: Color(red: 0.16, green: 0.58, blue: 0.94)
        }
    }
}
