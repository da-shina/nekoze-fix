import Foundation

/// Session layer: sensitivity and monitoring flag persistence (UserDefaults only).
/// See design.md "SettingsStore" section.

final class SettingsStore {
    // MARK: - Keys

    private enum Keys {
        static let sensitivity = "com.nekozefix.sensitivity"
        static let isMonitoringEnabled = "com.nekozefix.isMonitoringEnabled"
    }

    // MARK: - Properties

    private let defaults: UserDefaults

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    // MARK: - Public Properties

    /// User sensitivity value (0.0 to 1.0)
    /// Default: 0.5
    var sensitivity: Double {
        get { defaults.double(forKey: Keys.sensitivity) }
        set { defaults.set(newValue, forKey: Keys.sensitivity) }
    }

    /// Whether monitoring is enabled
    /// Default: false
    var isMonitoringEnabled: Bool {
        get { defaults.bool(forKey: Keys.isMonitoringEnabled) }
        set { defaults.set(newValue, forKey: Keys.isMonitoringEnabled) }
    }

    // MARK: - Public Methods

    /// Converts sensitivity (0.0-1.0) to slouch threshold in degrees
    /// Formula: 20 - (sensitivity * 15)
    /// - sensitivity 0.0 → 20 degrees
    /// - sensitivity 0.5 → 12.5 degrees
    /// - sensitivity 1.0 → 5 degrees
    /// - Returns: threshold in degrees
    func slouchDeltaThresholdDegrees() -> Double {
        // Linear mapping: 20 - (sensitivity * 15)
        return 20.0 - (sensitivity * 15.0)
    }

    // MARK: - Private Methods

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.sensitivity: 0.5,
            Keys.isMonitoringEnabled: false
        ])
    }
}