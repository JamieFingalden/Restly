import CoreGraphics
import Foundation

enum ActivityState: Equatable {
    case active
    case idle
    case away
    case sleeping

    var description: String {
        switch self {
        case .active: "计时中"
        case .idle: "等待操作"
        case .away: "未检测到操作"
        case .sleeping: "计时已暂停"
        }
    }
}

struct ActivitySample {
    let state: ActivityState
    let idleSeconds: TimeInterval
}

@MainActor
final class ActivityMonitor {
    private var isSleeping = false
    private let anyInputEventType = CGEventType(rawValue: UInt32.max)!

    func sample(settings: ReminderSettings) -> ActivitySample {
        guard !isSleeping else {
            return ActivitySample(state: .sleeping, idleSeconds: 0)
        }

        let idleSeconds = max(
            0,
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: anyInputEventType
            )
        )
        let idleThreshold = TimeInterval(settings.idleThresholdMinutes * 60)
        let awayThreshold = TimeInterval(settings.awayThresholdMinutes * 60)
        let state = Self.classify(
            idleSeconds: idleSeconds,
            idleThreshold: idleThreshold,
            awayThreshold: awayThreshold
        )
        return ActivitySample(state: state, idleSeconds: idleSeconds)
    }

    nonisolated static func classify(
        idleSeconds: TimeInterval,
        idleThreshold: TimeInterval,
        awayThreshold: TimeInterval
    ) -> ActivityState {
        if idleSeconds < idleThreshold { return .active }
        if idleSeconds < awayThreshold { return .idle }
        return .away
    }

    func markSleeping() {
        isSleeping = true
    }

    func markAwake() {
        isSleeping = false
    }
}
