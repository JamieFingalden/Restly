import AppKit
import SwiftUI

private struct EyeRestHeadsUpRequest {
    let onStart: () -> Void
    let onSnooze: () -> Void
}

private struct ScreenLockRequest {
    let onLock: () -> Void
}

private enum ActiveToastContent {
    case health(HealthToast)
    case eyeRest(EyeRestHeadsUpRequest)
    case screenLock(ScreenLockRequest)
}

private enum ToastDismissAction {
    case reminder(ReminderAction)
    case startEyeRest
    case snoozeEyeRest
    case lockScreen
    case cancelScreenLock
}

@MainActor
final class ToastManager: NSObject {
    var actionHandler: ((ReminderType, ReminderAction) -> Void)?

    // macOS 菜单栏底边与 Toast 之间的额外距离，需要实机微调时只改这里。
    static let topSafeArea: CGFloat = 20

    private let panelSize = NSSize(width: 324, height: 68)
    private let autoDismissDuration: Duration = .seconds(5)
    private let queueDelay: Duration = .milliseconds(1300)
    private var queue = HealthToastQueue()
    private var activeContent: ActiveToastContent?
    private var pendingEyeRestHeadsUp: EyeRestHeadsUpRequest?
    private var pendingScreenLock: ScreenLockRequest?
    private var activePanel: HealthToastPanel?
    private var presentation: ToastPresentationState?
    private var autoDismissTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var isDismissing = false
    private var autoDismissEnabled = false
    private var isQueueSuspended = false

    func show(
        _ type: ReminderType,
        intervalMinutes: Int,
        autoDismiss: Bool = false
    ) {
        guard let toastType = HealthToastType(reminderType: type) else { return }
        if case .health(let activeToast) = activeContent,
           activeToast.type == toastType {
            return
        }

        autoDismissEnabled = autoDismiss
        let toast = HealthToast(type: toastType, intervalMinutes: intervalMinutes)
        guard queue.enqueue(toast) else { return }
        presentNextIfPossible()
    }

    func showEyeRestHeadsUp(
        onStart: @escaping () -> Void,
        onSnooze: @escaping () -> Void
    ) {
        guard pendingEyeRestHeadsUp == nil else { return }
        if case .eyeRest = activeContent { return }

        pendingEyeRestHeadsUp = EyeRestHeadsUpRequest(
            onStart: onStart,
            onSnooze: onSnooze
        )
        presentNextIfPossible()
    }

    func showScreenLockCountdown(onLock: @escaping () -> Void) {
        guard pendingScreenLock == nil else { return }
        if case .screenLock = activeContent { return }

        pendingScreenLock = ScreenLockRequest(onLock: onLock)
        presentNextIfPossible()
    }

    func suspendQueue() {
        isQueueSuspended = true
    }

    func resumeQueue() {
        isQueueSuspended = false
        presentNextIfPossible()
    }

    func cancelEyeRestHeadsUp() {
        pendingEyeRestHeadsUp = nil
        if case .eyeRest = activeContent {
            dismissActive(action: nil)
        } else {
            presentNextIfPossible()
        }
    }

    func cancelScreenLockCountdown() {
        pendingScreenLock = nil
        if case .screenLock = activeContent {
            dismissActive(action: .cancelScreenLock)
        } else {
            presentNextIfPossible()
        }
    }

    private func presentNextIfPossible() {
        guard activeContent == nil,
              activePanel == nil,
              !isQueueSuspended,
              let screen = activeScreen() else {
            return
        }

        if let request = pendingScreenLock {
            pendingScreenLock = nil
            presentScreenLockCountdown(request, on: screen)
            return
        }

        if let request = pendingEyeRestHeadsUp {
            pendingEyeRestHeadsUp = nil
            presentEyeRestHeadsUp(request, on: screen)
            return
        }

        guard let toast = queue.dequeue() else { return }
        presentHealthToast(toast, on: screen)
    }

    private func presentHealthToast(_ toast: HealthToast, on screen: NSScreen) {
        let presentation = ToastPresentationState()
        let panel = makePanel(toast: toast, presentation: presentation)
        display(
            panel,
            content: .health(toast),
            presentation: presentation,
            on: screen
        )

        if autoDismissEnabled {
            autoDismissTask = Task { [weak self] in
                try? await Task.sleep(for: self?.autoDismissDuration ?? .seconds(5))
                guard !Task.isCancelled else { return }
                self?.dismissActive(action: nil)
            }
        }
    }

    private func presentEyeRestHeadsUp(
        _ request: EyeRestHeadsUpRequest,
        on screen: NSScreen
    ) {
        let presentation = ToastPresentationState()
        let countdown = ToastCountdownState(seconds: 5)
        let panel = makeEyeRestPanel(
            countdown: countdown,
            presentation: presentation
        )
        display(
            panel,
            content: .eyeRest(request),
            presentation: presentation,
            on: screen
        )

        autoDismissTask = Task { [weak self, weak countdown] in
            for seconds in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if seconds == 0 {
                    self?.dismissActive(action: .startEyeRest)
                } else {
                    countdown?.update(seconds: seconds)
                }
            }
        }
    }

    private func presentScreenLockCountdown(
        _ request: ScreenLockRequest,
        on screen: NSScreen
    ) {
        let presentation = ToastPresentationState()
        let countdown = ToastCountdownState(seconds: 2)
        let panel = makeScreenLockPanel(
            countdown: countdown,
            presentation: presentation
        )
        display(
            panel,
            content: .screenLock(request),
            presentation: presentation,
            on: screen
        )

        autoDismissTask = Task { [weak self, weak countdown] in
            for seconds in stride(from: 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if seconds == 0 {
                    self?.dismissActive(action: .lockScreen)
                } else {
                    countdown?.update(seconds: seconds)
                }
            }
        }
    }

    private func display(
        _ panel: HealthToastPanel,
        content: ActiveToastContent,
        presentation: ToastPresentationState,
        on screen: NSScreen
    ) {
        panel.setFrame(frame(on: screen), display: true)
        activeContent = content
        activePanel = panel
        self.presentation = presentation
        isDismissing = false

        // nonactivatingPanel + orderFrontRegardless 只展示，不改变当前键盘焦点。
        panel.orderFrontRegardless()
        // 先让 SwiftUI 绘制一帧隐藏态，再切换为显示态，避免内容直接硬切出现。
        DispatchQueue.main.async { [weak self, weak panel, weak presentation] in
            guard let self,
                  let panel,
                  self.activePanel === panel else {
                return
            }
            presentation?.show()
        }
        playReminderSound()
    }

    private func makePanel(
        toast: HealthToast,
        presentation: ToastPresentationState
    ) -> HealthToastPanel {
        let panel = makeBasePanel()
        let hostingView = FirstMouseHostingView(
            rootView: HealthToastView(
                toast: toast,
                presentation: presentation,
                onCompleted: { [weak self] in
                    self?.dismissActive(action: .reminder(.completed))
                },
                onSnoozed: { [weak self] in
                    self?.dismissActive(action: .reminder(.snoozed))
                }
            )
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        return panel
    }

    private func makeEyeRestPanel(
        countdown: ToastCountdownState,
        presentation: ToastPresentationState
    ) -> HealthToastPanel {
        let panel = makeBasePanel()
        let hostingView = FirstMouseHostingView(
            rootView: EyeRestHeadsUpView(
                countdown: countdown,
                presentation: presentation,
                onStart: { [weak self] in
                    self?.dismissActive(action: .startEyeRest)
                },
                onSnoozed: { [weak self] in
                    self?.dismissActive(action: .snoozeEyeRest)
                }
            )
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        return panel
    }

    private func makeScreenLockPanel(
        countdown: ToastCountdownState,
        presentation: ToastPresentationState
    ) -> HealthToastPanel {
        let panel = makeBasePanel()
        let hostingView = FirstMouseHostingView(
            rootView: ScreenLockCountdownView(
                countdown: countdown,
                presentation: presentation,
                onCancel: { [weak self] in
                    self?.dismissActive(action: .cancelScreenLock)
                }
            )
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        return panel
    }

    private func makeBasePanel() -> HealthToastPanel {
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
        return panel
    }

    private func dismissActive(action: ToastDismissAction?) {
        guard !isDismissing,
              let content = activeContent,
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
            self?.activeContent = nil
            self?.isDismissing = false

            self?.perform(action, for: content)

            try? await Task.sleep(for: self?.queueDelay ?? .milliseconds(1300))
            guard !Task.isCancelled else { return }
            self?.presentNextIfPossible()
        }
    }

    private func perform(
        _ action: ToastDismissAction?,
        for content: ActiveToastContent
    ) {
        switch (content, action) {
        case (.health(let toast), .reminder(let reminderAction)):
            actionHandler?(toast.type.reminderType, reminderAction)
        case (.eyeRest(let request), .startEyeRest):
            request.onStart()
        case (.eyeRest(let request), .snoozeEyeRest):
            request.onSnooze()
        case (.screenLock(let request), .lockScreen):
            request.onLock()
        default:
            break
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

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
private final class ToastCountdownState: ObservableObject {
    @Published private(set) var remainingSeconds: Int

    init(seconds: Int) {
        remainingSeconds = max(1, seconds)
    }

    func update(seconds: Int) {
        remainingSeconds = max(1, seconds)
    }
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

                HStack(spacing: 6) {
                    Button(toast.type.primaryActionTitle, action: onCompleted)
                        .buttonStyle(
                            ToastActionButtonStyle(
                                accentColor: accentColor,
                                isPrimary: true
                            )
                        )
                    Button("5 分钟后", action: onSnoozed)
                        .buttonStyle(
                            ToastActionButtonStyle(
                                accentColor: accentColor,
                                isPrimary: false
                            )
                        )
                }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }

            Spacer(minLength: 0)
        }
        .toastChrome(accentColor: accentColor, presentation: presentation)
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

private struct EyeRestHeadsUpView: View {
    @ObservedObject var countdown: ToastCountdownState
    @ObservedObject var presentation: ToastPresentationState
    let onStart: () -> Void
    let onSnoozed: () -> Void

    private let accentColor = Color(red: 0.46, green: 0.4, blue: 0.94)

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.16))
                Image(systemName: "eye.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(accentColor)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text("准备休息眼睛")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(countdown.remainingSeconds) 秒后开始")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 6) {
                    Button("现在休息", action: onStart)
                        .buttonStyle(
                            ToastActionButtonStyle(
                                accentColor: accentColor,
                                isPrimary: true
                            )
                        )
                    Button("5 分钟后", action: onSnoozed)
                        .buttonStyle(
                            ToastActionButtonStyle(
                                accentColor: accentColor,
                                isPrimary: false
                            )
                        )
                }
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }

            Spacer(minLength: 0)
        }
        .toastChrome(accentColor: accentColor, presentation: presentation)
        .accessibilityElement(children: .contain)
    }
}

private struct ScreenLockCountdownView: View {
    @ObservedObject var countdown: ToastCountdownState
    @ObservedObject var presentation: ToastPresentationState
    let onCancel: () -> Void

    private let accentColor = Color(red: 0.94, green: 0.52, blue: 0.2)

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.16))
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(accentColor)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text("即将锁定屏幕")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(countdown.remainingSeconds) 秒后")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Button("取消", action: onCancel)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .buttonStyle(
                        ToastActionButtonStyle(
                            accentColor: accentColor,
                            isPrimary: true
                        )
                    )
            }

            Spacer(minLength: 0)
        }
        .toastChrome(accentColor: accentColor, presentation: presentation)
        .accessibilityElement(children: .contain)
    }
}

private struct ToastActionButtonStyle: ButtonStyle {
    let accentColor: Color
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .foregroundStyle(
                isPrimary ? accentColor : Color(nsColor: .secondaryLabelColor)
            )
            .background(
                isPrimary
                    ? accentColor.opacity(configuration.isPressed ? 0.24 : 0.13)
                    : Color.primary.opacity(configuration.isPressed ? 0.13 : 0.06),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        isPrimary
                            ? accentColor.opacity(0.18)
                            : Color(nsColor: .separatorColor).opacity(0.7),
                        lineWidth: 0.7
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private extension View {
    func toastChrome(
        accentColor: Color,
        presentation: ToastPresentationState
    ) -> some View {
        padding(.horizontal, 14)
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
            .scaleEffect(presentation.isVisible ? 1 : 0.975)
            .blur(radius: presentation.isVisible ? 0 : 1.5)
            .offset(y: presentation.isVisible ? 0 : -7)
            .animation(
                presentation.isVisible
                    ? .spring(response: 0.38, dampingFraction: 0.88, blendDuration: 0.12)
                    : .easeInOut(duration: 0.18),
                value: presentation.isVisible
            )
    }
}
