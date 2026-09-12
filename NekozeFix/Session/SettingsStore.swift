import Foundation
import Combine

/// セッション層: 猫背閾値と監視フラグの永続化（UserDefaults のみ）。
/// design.md "SettingsStore" セクション参照。

final class SettingsStore: ObservableObject {
    // MARK: - キー

    private enum Keys {
        /// 旧・感度キー（廃止済み。初回起動時に閾値へ一度だけ変換して削除）
        static let legacySensitivity = "com.nekozefix.sensitivity"
        static let slouchThresholdDegrees = "com.nekozefix.slouchThresholdDegrees"
        static let isMonitoringEnabled = "com.nekozefix.isMonitoringEnabled"
        static let cameraPosition = "com.nekozefix.cameraPosition"
    }

    // MARK: - 定数

    /// 閾値の下限（度）
    static let thresholdMinDegrees: Double = 5.0
    /// 閾値の上限（度）
    static let thresholdMaxDegrees: Double = 20.0
    /// デフォルト閾値（度）。少々の前方頭出しも通知する厳しめ設定
    static let thresholdDefaultDegrees: Double = 8.0

    // MARK: - プロパティ

    private let defaults: UserDefaults

    // MARK: - 初期化

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // 閾値の読込。未設定なら旧感度キーから一度だけ変換して引き継ぐ
        // （旧マッピング: 20 - sensitivity * 15）
        if let saved = defaults.object(forKey: Keys.slouchThresholdDegrees) as? Double {
            self.slouchThresholdDegrees = saved
        } else if defaults.object(forKey: Keys.legacySensitivity) != nil {
            let legacy = defaults.double(forKey: Keys.legacySensitivity)
            self.slouchThresholdDegrees = SettingsStore.clamp(20.0 - legacy * 15.0)
        } else {
            self.slouchThresholdDegrees = SettingsStore.thresholdDefaultDegrees
        }
        defaults.removeObject(forKey: Keys.legacySensitivity)

        self.isMonitoringEnabled = defaults.bool(forKey: Keys.isMonitoringEnabled)

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

    /// 猫背判定閾値（度）。基準姿勢からの角度増加量がこの値以上で猫背候補。
    /// 範囲: 5.0〜20.0、デフォルト: 8.0
    @Published var slouchThresholdDegrees: Double {
        didSet {
            let clamped = SettingsStore.clamp(slouchThresholdDegrees)
            if clamped != slouchThresholdDegrees {
                slouchThresholdDegrees = clamped // didSet 再入で保存
                return
            }
            defaults.set(slouchThresholdDegrees, forKey: Keys.slouchThresholdDegrees)
        }
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

    // MARK: - プライベートメソッド

    private static func clamp(_ value: Double) -> Double {
        min(thresholdMaxDegrees, max(thresholdMinDegrees, value))
    }

    private func registerDefaults() {
        // slouchThresholdDegrees をここに registered default として登録しないこと：
        // object(forKey:) が登録値を返し、旧感度キーからの移行判定がマスクされる。
        // デフォルト値は init の else 分岐（thresholdDefaultDegrees）で担保する。
        defaults.register(defaults: [
            Keys.isMonitoringEnabled: false,
            Keys.cameraPosition: CameraPosition.front.rawValue
        ])
    }
}