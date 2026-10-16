import Foundation

/// 省電力段階（通常・暗転・長時間不在）の3値。所有は `DimPowerPolicy`。
enum DimPowerStage: Equatable {
    case normal
    case dimmed
    case dimmedAbsent
}

/// 省電力段階方針（Session層・純粋値型・錠なし）。
///
/// 段階定義・遷移判定・復帰則・不在しきい値を単一に所有する。
/// 遷移の入力は暗転操作と検出結果（デバウンス済み）のみとし、
/// 輝度・スリープ抑止の状態には従属しない。
/// 判定経路は既存の直列実行に従い錠を新設しない。
/// 推論上限・取得頻度の具体値マッピングは所有せず、Session側が持つ（ADR-0024）。
///
/// 設計参照: `.kiro/specs/dim-mode-saving/design.md`「Session / DimPowerPolicy」。
/// 用語参照: `CONTEXT.md`（省電力段階・長時間不在・不在しきい値・復帰）。
struct DimPowerPolicy: Equatable {
    /// 不在しきい値の既定値（秒）。実測記録で見直す仮置き（ADR-0024）。
    static let defaultAbsentThreshold: TimeInterval = 60

    /// 現在段階。
    private(set) var stage: DimPowerStage = .normal
    /// 不在しきい値（秒）。判定中に変わらない。
    let absentThreshold: TimeInterval
    /// 暗転中の連続不在の開始時刻（単調時計）。人物検出中・通常段階では nil。
    private var absentStart: TimeInterval?

    /// - Parameter absentThreshold: 人物なし継続秒数（正の有限値）。不正値は既定値に倒す。
    init(absentThreshold: TimeInterval = DimPowerPolicy.defaultAbsentThreshold) {
        self.absentThreshold = absentThreshold.isFinite && absentThreshold > 0
            ? absentThreshold
            : Self.defaultAbsentThreshold
    }

    /// 暗転移行。暗転段階へ進め、不在計測を起点からやり直す。
    /// - Returns: 遷移後の段階。
    mutating func dimmed() -> DimPowerStage {
        stage = .dimmed
        absentStart = nil
        return stage
    }

    /// 暗転解除・監視開始・フォアグラウンド復帰。通常段階へ戻し、不在計測を破棄する。
    /// - Returns: 遷移後の段階（常に `.normal`）。
    mutating func restored() -> DimPowerStage {
        stage = .normal
        absentStart = nil
        return stage
    }

    /// 検出結果による段階遷移判定。判定ロジックへの介入は行わない。
    ///
    /// - Parameters:
    ///   - isPersonDetected: デバウンス済みの人物検出状態（`updateState`確定後の値）。
    ///     生検出は使わない（瞬断振動を避けるため）。
    ///   - now: 単調時刻系（`CACurrentMediaTime`系、`FrameThrottle`と同一時計）。
    ///     暦時刻・壁時計系は用いない。無効時刻（NaN・負・無限大）は遷移を見送る。
    /// - Returns: 判定後の段階（遷移なしの場合は現段階を維持）。
    mutating func tick(isPersonDetected: Bool, now: TimeInterval) -> DimPowerStage {
        guard now.isFinite, now >= 0 else { return stage }
        if isPersonDetected {
            absentStart = nil
            if stage == .dimmedAbsent {
                stage = .dimmed
            }
            return stage
        }
        guard stage == .dimmed || stage == .dimmedAbsent else { return stage }
        guard stage == .dimmed else { return stage }
        guard let start = absentStart else {
            absentStart = now
            return stage
        }
        guard now >= start else {
            absentStart = now
            return stage
        }
        if now - start > absentThreshold {
            stage = .dimmedAbsent
        }
        return stage
    }
}
