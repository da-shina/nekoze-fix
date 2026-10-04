import Foundation
import Combine

/// セッション層: 猫背閾値と監視フラグの永続化（UserDefaults のみ）。
/// design.md "SettingsStore" セクション参照。

final class SettingsStore: ObservableObject {
    // MARK: - キー

    private enum Keys {
        static let legacySensitivity = "com.nekozefix.sensitivity"
        static let slouchThresholdDegrees = "com.nekozefix.slouchThresholdDegrees"
        static let slouchDistanceThresholdPercent = "com.nekozefix.slouchDistanceThresholdPercent"
        static let isMonitoringEnabled = "com.nekozefix.isMonitoringEnabled"
        static let cameraPosition = "com.nekozefix.cameraPosition"
    }

    // MARK: - 定数

    /// 閾値の下限（度）
    static let thresholdMinDegrees: Double = 1.0
    /// 閾値の上限（度）
    static let thresholdMaxDegrees: Double = 20.0
    /// デフォルト閾値（度）。少々の前方頭出しも通知する厳しめ設定
    static let thresholdDefaultDegrees: Double = 5.0
    /// 距離閾値の下限（%）。FQ4
    static let distanceThresholdMinPercent: Double = 1.0
    /// 距離閾値の上限（%）。FQ4
    static let distanceThresholdMaxPercent: Double = 30.0
    /// 距離閾値のデフォルト（%）。FQ2/FQ4
    static let distanceThresholdDefaultPercent: Double = 8.0

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
            self.slouchThresholdDegrees = SettingsStore.clamp(20.0 - legacy * 15.0, to: SettingsStore.thresholdMinDegrees...SettingsStore.thresholdMaxDegrees)
        } else {
            self.slouchThresholdDegrees = SettingsStore.thresholdDefaultDegrees
        }
        defaults.removeObject(forKey: Keys.legacySensitivity)

        // 距離閾値の読込。新キーなので旧キー移行は不要、未設定ならデフォルト（角度と同様の扱い）
        if let saved = defaults.object(forKey: Keys.slouchDistanceThresholdPercent) as? Double {
            self.slouchDistanceThresholdPercent = Self.clamp(saved, to: SettingsStore.distanceThresholdMinPercent...SettingsStore.distanceThresholdMaxPercent)
        } else {
            self.slouchDistanceThresholdPercent = SettingsStore.distanceThresholdDefaultPercent
        }

        self.isMonitoringEnabled = defaults.bool(forKey: Keys.isMonitoringEnabled)

        // カメラ位置の読込
        if let posString = defaults.string(forKey: Keys.cameraPosition),
           let pos = CameraPosition(rawValue: posString) {
            self.cameraPosition = pos
        } else {
            self.cameraPosition = .front
        }
    }

    // MARK: - 公開プロパティ

    /// 猫背判定閾値（度）。基準姿勢からの角度増加量がこの値以上で猫背候補。
    /// 範囲: 3.0〜20.0、デフォルト: 5.0
    @Published var slouchThresholdDegrees: Double {
        didSet {
            let clamped = SettingsStore.clamp(slouchThresholdDegrees, to: Self.thresholdMinDegrees...Self.thresholdMaxDegrees)
            if clamped != slouchThresholdDegrees {
                slouchThresholdDegrees = clamped // didSet 再入で保存
                return
            }
            defaults.set(slouchThresholdDegrees, forKey: Keys.slouchThresholdDegrees)
        }
    }

    /// 前出し距離の判定閾値（基準比%）。ロック側の耳-肩距離が基準のこの%以上で猫背候補。
    /// 範囲: 1.0〜30.0（ステップ 0.5 は UI 側）、デフォルト: 8.0
    @Published var slouchDistanceThresholdPercent: Double {
        didSet {
            let clamped = SettingsStore.clamp(slouchDistanceThresholdPercent, to: Self.distanceThresholdMinPercent...Self.distanceThresholdMaxPercent)
            if clamped != slouchDistanceThresholdPercent {
                slouchDistanceThresholdPercent = clamped // didSet 再入で保存
                return
            }
            defaults.set(slouchDistanceThresholdPercent, forKey: Keys.slouchDistanceThresholdPercent)
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

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}