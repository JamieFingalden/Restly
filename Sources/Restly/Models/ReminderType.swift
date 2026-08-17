import Foundation

enum ReminderType: String, CaseIterable, Identifiable, Sendable {
    case water
    case eyeRest
    case stand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .water: "喝水"
        case .eyeRest: "眼睛休息"
        case .stand: "站起来"
        }
    }

    var shortTitle: String {
        switch self {
        case .water: "喝水"
        case .eyeRest: "眼睛"
        case .stand: "站立"
        }
    }

    var systemImage: String {
        switch self {
        case .water: "drop.fill"
        case .eyeRest: "eye.fill"
        case .stand: "figure.stand"
        }
    }
}

enum ReminderAction: Sendable {
    case completed
    case skipped
    case snoozed
}
