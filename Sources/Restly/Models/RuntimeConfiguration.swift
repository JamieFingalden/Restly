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

    @MainActor
    func pomodoroDuration(for phase: PomodoroSession.Phase, settings: ReminderSettings) -> TimeInterval {
        if isDevelopmentMode {
            switch phase {
            case .focus: return 30
            case .shortBreak: return 10
            case .longBreak: return 20
            }
        }

        switch phase {
        case .focus: return TimeInterval(settings.pomodoroFocusMinutes * 60)
        case .shortBreak: return TimeInterval(settings.pomodoroShortBreakMinutes * 60)
        case .longBreak: return TimeInterval(settings.pomodoroLongBreakMinutes * 60)
        }
    }
}
