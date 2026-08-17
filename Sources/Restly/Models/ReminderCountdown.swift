import Foundation

struct ReminderCountdown: Equatable {
    private(set) var remaining: TimeInterval

    init(duration: TimeInterval) {
        remaining = max(0, duration)
    }

    mutating func advance(by elapsed: TimeInterval, whileActive: Bool) -> Bool {
        guard whileActive, remaining > 0 else { return false }
        remaining = max(0, remaining - max(0, elapsed))
        return remaining == 0
    }

    mutating func reset(to duration: TimeInterval) {
        remaining = max(0, duration)
    }
}
