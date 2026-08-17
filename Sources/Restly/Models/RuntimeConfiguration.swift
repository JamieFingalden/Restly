import Foundation

struct RuntimeConfiguration {
    let isDevelopmentMode: Bool
    let showsEyeRestOnLaunch: Bool

    static let current = RuntimeConfiguration(
        isDevelopmentMode: ProcessInfo.processInfo.arguments.contains("--development-mode")
            || ProcessInfo.processInfo.environment["RESTLY_DEVELOPMENT_MODE"] == "1",
        showsEyeRestOnLaunch: ProcessInfo.processInfo.arguments.contains("--show-eye-rest")
    )

    @MainActor
    func interval(for type: ReminderType, settings: ReminderSettings) -> TimeInterval {
        if isDevelopmentMode {
            switch type {
            case .eyeRest: return 30
            case .water: return 60
            case .stand: return 90
            }
        }

        switch type {
        case .water: return TimeInterval(settings.waterIntervalMinutes * 60)
        case .eyeRest: return TimeInterval(settings.eyeIntervalMinutes * 60)
        case .stand: return TimeInterval(settings.standIntervalMinutes * 60)
        }
    }
}
