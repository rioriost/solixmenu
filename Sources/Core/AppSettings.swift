import Foundation

enum AppSettingsKeys {
    static let debugLogEnabled = "SolixMenuDebugLogEnabled"
}

@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isDebugLogEnabled: Bool {
        get {
            defaults.bool(forKey: AppSettingsKeys.debugLogEnabled)
        }
        set {
            defaults.set(newValue, forKey: AppSettingsKeys.debugLogEnabled)
            AppLogger.shared.setFileLoggingEnabled(newValue)
        }
    }
}
