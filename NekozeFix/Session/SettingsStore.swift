import Foundation

/// セッション層: 感度と監視フラグの永続化（UserDefaults のみ）。
/// design.md "SettingsStore" セクション参照。

final class SettingsStore {
    // MARK: - キー

    private enum Keys {
        static let sensitivity = "com.nekozefix.sensitivity"
        static let isMonitoringEnabled = "com.nekozefix.isMonitoringEnabled"
    }

    // MARK: - プロパティ

    private let defaults: UserDefaults

    // MARK: - 初期化

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    // MARK: - 公開プロパティ

    /// ユーザーの感度値（0.0 〜 1.0）
    /// デフォルト: 0.5
    var sensitivity: Double {
        get { defaults.double(forKey: Keys.sensitivity) }
        set { defaults.set(newValue, forKey: Keys.sensitivity) }
    }

    /// 監視が有効かどうか
    /// デフォルト: false
    var isMonitoringEnabled: Bool {
        get { defaults.bool(forKey: Keys.isMonitoringEnabled) }
        set { defaults.set(newValue, forKey: Keys.isMonitoringEnabled) }
    }

    // MARK: - 公開メソッド

    /// 感度（0.0〜1.0）を猫背閾値（度数）に変換する
    /// 計算式: 20 - (sensitivity * 15)
    /// - sensitivity 0.0 → 20 度
    /// - sensitivity 0.5 → 12.5 度
    /// - sensitivity 1.0 → 5 度
    /// - Returns: 閾値（度数）
    func slouchDeltaThresholdDegrees() -> Double {
        // 線形マッピング: 20 - (sensitivity * 15)
        return 20.0 - (sensitivity * 15.0)
    }

    // MARK: - プライベートメソッド

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.sensitivity: 0.5,
            Keys.isMonitoringEnabled: false
        ])
    }
}