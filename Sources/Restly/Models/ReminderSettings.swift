import Foundation

@MainActor
final class ReminderSettings: ObservableObject {
    @Published var waterEnabled: Bool {
        didSet { persist(waterEnabled, forKey: Keys.waterEnabled) }
    }

    @Published var waterIntervalMinutes: Int {
        didSet { persist(waterIntervalMinutes, forKey: Keys.waterIntervalMinutes) }
    }

    @Published var eyeEnabled: Bool {
        didSet { persist(eyeEnabled, forKey: Keys.eyeEnabled) }
    }

    @Published var eyeIntervalMinutes: Int {
        didSet { persist(eyeIntervalMinutes, forKey: Keys.eyeIntervalMinutes) }
    }

    @Published var eyeRestDurationSeconds: Int {
        didSet { persist(eyeRestDurationSeconds, forKey: Keys.eyeRestDurationSeconds) }
    }

    @Published var standEnabled: Bool {
        didSet { persist(standEnabled, forKey: Keys.standEnabled) }
    }

    @Published var standIntervalMinutes: Int {
        didSet { persist(standIntervalMinutes, forKey: Keys.standIntervalMinutes) }
    }

    @Published var idleThresholdMinutes: Int {
        didSet { persist(idleThresholdMinutes, forKey: Keys.idleThresholdMinutes) }
    }

    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        waterEnabled = defaults.object(forKey: Keys.waterEnabled) as? Bool ?? true
        waterIntervalMinutes = defaults.object(forKey: Keys.waterIntervalMinutes) as? Int ?? 45
        eyeEnabled = defaults.object(forKey: Keys.eyeEnabled) as? Bool ?? true
        eyeIntervalMinutes = defaults.object(forKey: Keys.eyeIntervalMinutes) as? Int ?? 30
        eyeRestDurationSeconds = defaults.object(forKey: Keys.eyeRestDurationSeconds) as? Int ?? 20
        standEnabled = defaults.object(forKey: Keys.standEnabled) as? Bool ?? true
        standIntervalMinutes = defaults.object(forKey: Keys.standIntervalMinutes) as? Int ?? 50
        idleThresholdMinutes = defaults.object(forKey: Keys.idleThresholdMinutes) as? Int ?? 3
        isLoading = false
    }

    func isEnabled(_ type: ReminderType) -> Bool {
        switch type {
        case .water: waterEnabled
        case .eyeRest: eyeEnabled
        case .stand: standEnabled
        }
    }

    var awayThresholdMinutes: Int {
        max(idleThresholdMinutes + 2, 8)
    }

    private func persist(_ value: Any, forKey key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
        onChange?()
    }

    private enum Keys {
        static let waterEnabled = "waterEnabled"
        static let waterIntervalMinutes = "waterIntervalMinutes"
        static let eyeEnabled = "eyeEnabled"
        static let eyeIntervalMinutes = "eyeIntervalMinutes"
        static let eyeRestDurationSeconds = "eyeRestDurationSeconds"
        static let standEnabled = "standEnabled"
        static let standIntervalMinutes = "standIntervalMinutes"
        static let idleThresholdMinutes = "idleThresholdMinutes"
    }
}
