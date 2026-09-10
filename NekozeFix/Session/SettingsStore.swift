import Foundation
import Combine

/// セッション層: 感度と監視フラグの永続化（UserDefaults のみ）。
/// design.md "SettingsStore" セクション参照。

final class SettingsStore: ObservableObject {
    // MARK: - キー

    private enum Keys {
        static let sensitivity = "com.nekozefix.sensitivity"
        static let isMonitoringEnabled = "com.nekozefix.isMonitoringEnabled"
        static let cameraPosition = "com.nekozefix.cameraPosition"
    }

    // MARK: - プロパティ

    private let defaults: UserDefaults

    // MARK: - 初期化

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // まずデフォルト値を設定
        let savedSensitivity = defaults.double(forKey: Keys.sensitivity)
        let savedEnabled = defaults.bool(forKey: Keys.isMonitoringEnabled)
        self.sensitivity = (savedSensitivity == 0 && defaults.object(forKey: Keys.sensitivity) == nil) ? 0.5 : savedSensitivity
        self.isMonitoringEnabled = savedEnabled

        // カメラ位置の読込
        if let posString = defaults.string(forKey: Keys.cameraPosition),
           let pos = CameraPosition(rawValue: posString) {
            self.cameraPosition = pos
        } else {
            self.cameraPosition = .front
        }

        // 初期化後にregisterDefaultsを呼ぶ
        registerDefaults()
    }

    // MARK: - 公開プロパティ

    /// ユーザーの感度値（0.0 〜 1.0）
    /// デフォルト: 0.5
    @Published var sensitivity: Double {
        didSet { defaults.set(sensitivity, forKey: Keys.sensitivity) }
    }

    /// 監視が有効かどうか
    /// デフォルト: false
    @Published var isMonitoringEnabled: Bool {
        didSet { defaults.set(isMonitoringEnabled, forKey: Keys.isMonitoringEnabled) }
    }

    /// 使用するカメラの位置 (前面/背面)
    /// デフォルト: .front
    @Published var cameraPosition: CameraPosition {
        didSet { defaults.set(cameraPosition.rawValue, forKey: Keys.cameraPosition) }
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
            Keys.isMonitoringEnabled: false,
            Keys.cameraPosition: CameraPosition.front.rawValue
        ])
    }
}