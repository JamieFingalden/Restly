import AppKit
import SwiftUI

@MainActor
final class EyeRestSession: ObservableObject {
    @Published private(set) var remainingSeconds: Int
    let totalSeconds: Int

    var progress: Double {
        progress(at: Date())
    }

    private let onFinish: (ReminderAction) -> Void
    private var timer: Timer?
    private var endDate: Date?

    init(durationSeconds: Int, onFinish: @escaping (ReminderAction) -> Void) {
        let duration = max(1, durationSeconds)
        remainingSeconds = duration
        totalSeconds = duration
        self.onFinish = onFinish
    }

    func start(at startDate: Date = Date()) {
        cancel()
        endDate = startDate.addingTimeInterval(TimeInterval(totalSeconds))
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick(at: Date())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func progress(at date: Date) -> Double {
        guard let endDate else {
            return Double(remainingSeconds) / Double(totalSeconds)
        }
        return min(max(endDate.timeIntervalSince(date) / Double(totalSeconds), 0), 1)
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

    private func tick(at date: Date) {
        guard let endDate else { return }
        remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSince(date))))
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
        panel.backgroundColor = NSColor(calibratedWhite: 0.008, alpha: 1)
        panel.isOpaque = true
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        let hostingView = NSHostingView(rootView: ReminderOverlayView(session: session))
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        return panel
    }
}

private final class RestlyOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
