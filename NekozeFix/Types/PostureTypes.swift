import Foundation
import AVFoundation

// 型層: 共通の値オブジェクトと列挙型。
// 完全な仕様は design.md "Types" セクション参照。

enum CameraPosition: String, Codable, Equatable {
    case front
    case back

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }
}

enum CameraAuthorization {
    case notDetermined
    case authorized
    case denied
}

enum DetectionPresence {
    case personDetected
    case personMissing
}

struct Keypoint: Equatable {
    var x: Double
    var y: Double
    var confidence: Double
}

struct PoseFrame: Equatable {
    var timestamp: TimeInterval
    var leftEar: Keypoint?
    var rightEar: Keypoint?
    var leftShoulder: Keypoint?
    var rightShoulder: Keypoint?
}

enum Side: Equatable {
    case left
    case right
}

struct AngleSample: Equatable {
    var nearSide: Side
    var nearAngleDegrees: Double
    var farSideDetected: Bool
    /// 近傍側の耳-肩距離（Vision 正規化座標系、単位の基準なし）。前出し検出の第2指標。
    var nearDistance: Double
    /// 遠側の耳-肩角度（両側検出時のみ非nil）。両側距離基準対応。
    var farAngleDegrees: Double? = nil
    /// 遠側の耳-肩距離（両側検出時のみ非nil）。両側距離基準対応。
    var farDistance: Double? = nil
}

enum PostureVerdict: Equatable {
    case good
    case slouchCandidate
    case insufficientKeypoints
}

enum SessionPhase: Equatable {
    case awaitingPermission
    case permissionDenied
    case calibrating
    case idle
    case monitoring
    case rotating
}

enum DisplayedPosture: Equatable {
    case good
    case slouch
    case personMissing
}

enum CalibrationProgress: Equatable {
    case waitingForPerson
    case accumulating(elapsed: TimeInterval)
    case completed(referenceNearAngleDegrees: Double, referenceDistance: Double, referenceSide: Side, referencePoints: [CGPoint], referenceFarAngleDegrees: Double? = nil, referenceFarDistance: Double? = nil)
}

/// 距離指標の評価に必要データ（Session 層が校正完了時に構成し監視中保持・FQ1）。
struct DistanceMetric: Equatable {
    var side: Side                // 校正時にロックした側
    var referenceDistance: Double // 校正時耳-肩距離の平均（正規化座標系）
    /// 反対側の基準距離（両側校正時に設定。ロック側欠測時のフォールバック用）。
    var fallbackReferenceDistance: Double? = nil
}

struct SessionSnapshot: Equatable {
    var phase: SessionPhase = .awaitingPermission
    var displayedPosture: DisplayedPosture = .good
    var isDimmed: Bool = false
    var isPersonDetected: Bool = false
    /// 人物は映っているが肩のキーポイントが読めない状態（顔のみ検出）。
    /// 校正中の「肩が映っていません」案内に使用。
    var isShoulderMissing: Bool = false
    var showGuideline: Bool = false
    var isMonitoringEnabled: Bool = false
    var slouchGate: TimedConditionGate = TimedConditionGate(requiredDuration: 3.0)
    /// 表示用姿勢の dwell ゲート（0.5秒連続で slouchCandidate のときのみ .slouch 表示。
    /// good 方向は即時反映。フレームノイズによる一瞬の誤表示を防止）。
    var postureDisplayGate: TimedConditionGate = TimedConditionGate(requiredDuration: 0.5)
    var calibrationProgress: CalibrationProgress = .waitingForPerson
    var referenceAngle: Double? = nil
    /// 校正時耳-肩距離の平均（正規化座標系）。左右それぞれ保持。
    var referenceDistances: [Side: Double] = [:]
    /// 校正時にロックした側（FQ1）。監視中の距離評価はこの側の耳-肩ペアで行う。
    var referenceSide: Side? = nil
    var referencePoints: [CGPoint]? = nil
    var visualizationPoints: [CGPoint] = []
    /// キャプチャ画像のアスペクト比（バッファ実寸から算出）。可視化のクロップ補正に使用。
    var videoAspectRatio: CGFloat = 4.0 / 3.0
    var nearSide: Side? = nil
    /// 現在の端末向きがランドスケープか（なで肩ガイダンスの分岐に使用。ADR 0014）。
    var isLandscape: Bool = false
    /// 現在のビデオ向き。オーバーレイの座標変換に使用。
    var videoOrientation: AVCaptureVideoOrientation = .portrait
}

/// 肩キーポイント欠測時のガイダンス文言（ADR 0014）。
/// ランドスケープは縦画角がセンサー短辺に刈り込まれなで肩の肩が画角から落ちるため、
/// 実機検収で有効確認済みの手段を案内する。
func shoulderMissingGuidance(isLandscape: Bool) -> String {
    isLandscape
        ? "肩を認識できません。カメラを少し離すか、フロアからの高さを少し上げてください。"
        : "肩を認識できません。画面に肩まで収めてください。"
}

/// キーポイントを解析に含めるための最低信頼度閾値。
// 設計仕様: confidence < 0.3 → 猫背検出から除外（なで肩等の低信頼度帯を救うため 0.5 → 0.3 に改訂）。
let minimumKeypointConfidence: Double = 0.3
