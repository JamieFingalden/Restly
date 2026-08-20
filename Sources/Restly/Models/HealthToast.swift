import Foundation
import CoreGraphics

enum HealthToastType: Equatable {
    case water
    case stand

    init?(reminderType: ReminderType) {
        switch reminderType {
        case .water: self = .water
        case .stand: self = .stand
        case .eyeRest: return nil
        }
    }

    var reminderType: ReminderType {
        switch self {
        case .water: .water
        case .stand: .stand
        }
    }

    var title: String {
        switch self {
        case .water: "喝点水吧"
        case .stand: "起来活动一下"
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .water: "已喝"
        case .stand: "我起来了"
        }
    }
}

struct HealthToast: Identifiable, Equatable {
    let id: UUID
    let type: HealthToastType
    let intervalMinutes: Int

    init(
        id: UUID = UUID(),
        type: HealthToastType,
        intervalMinutes: Int
    ) {
        self.id = id
        self.type = type
        self.intervalMinutes = max(1, intervalMinutes)
    }

    var durationText: String {
        switch type {
        case .water: "已经 \(intervalMinutes) 分钟"
        case .stand: "连续 \(intervalMinutes) 分钟"
        }
    }
}

struct HealthToastQueue {
    private var pending: [HealthToast] = []

    var count: Int { pending.count }
    var isEmpty: Bool { pending.isEmpty }

    @discardableResult
    mutating func enqueue(_ toast: HealthToast) -> Bool {
        guard !pending.contains(where: { $0.type == toast.type }) else {
            return false
        }
        pending.append(toast)
        return true
    }

    mutating func dequeue() -> HealthToast? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

struct HealthToastLayout {
    static func frame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        toastSize: CGSize,
        topSafeArea: CGFloat
    ) -> CGRect {
        let origin = CGPoint(
            x: screenFrame.midX - toastSize.width / 2,
            y: max(
                visibleFrame.minY + 12,
                visibleFrame.maxY - topSafeArea - toastSize.height
            )
        )
        return CGRect(origin: origin, size: toastSize)
    }
}
