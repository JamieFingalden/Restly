import AppKit
import SwiftUI

@MainActor
final class EyeRestSession: ObservableObject {
    @Published private(set) var remainingSeconds: Int
    let totalSeconds: Int

    var progress: Double {
        Double(remainingSeconds) / Double(totalSeconds)
    }

    private let onFinish: (ReminderAction) -> Void
    private var timer: Timer?

    init(durationSeconds: Int, onFinish: @escaping (ReminderAction) -> Void) {
        let duration = max(1, durationSeconds)
        remainingSeconds = duration
        totalSeconds = duration
        self.onFinish = onFinish
    }

    func start() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func skip() {
        finish(with: .skipped)
    }

    func snooze() {
        finish(with: .snoozed)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        remainingSeconds -= 1
        if remainingSeconds <= 0 {
            finish(with: .completed)
        }
    }

    private func finish(with action: ReminderAction) {
        cancel()
        onFinish(action)
    }
}

@MainActor
final class EyeRestOverlayController {
    private var panels: [NSPanel] = []
    private var session: EyeRestSession?

    var isVisible: Bool { panels.contains { $0.isVisible } }

    func show(durationSeconds: Int, onFinish: @escaping (ReminderAction) -> Void) {
        dismiss()

        let session = EyeRestSession(durationSeconds: durationSeconds) { [weak self] action in
            self?.dismiss()
            onFinish(action)
        }
        let mouseLocation = NSEvent.mouseLocation
        let primaryScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens

        panels = screens.map { screen in
            makePanel(for: screen, session: session)
        }

        self.session = session
        NSApp.activate(ignoringOtherApps: true)
        for panel in panels {
            if panel.screen == primaryScreen {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }
        session.start()
    }

    func dismiss() {
        session?.cancel()
        session = nil
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
    }

    private func makePanel(for screen: NSScreen, session: EyeRestSession) -> NSPanel {
        let panel = RestlyOverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.setFrame(screen.frame, display: true)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        let visualEffectView = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        visualEffectView.material = .fullScreenUI
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(rootView: ReminderOverlayView(session: session))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])
        panel.contentView = visualEffectView
        return panel
    }
}

private final class RestlyOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
