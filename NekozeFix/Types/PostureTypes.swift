import Foundation
import AVFoundation
import Combine

// 型層: 共通の値オブジェクトと列挙型。
// 完全な仕様は design.md "Types" セクション参照.

/// Capture/Preview 接続の回転・ミラー適用に使う共通シーム（テスト容易性）。
/// 本番は `AVCaptureConnection` が適合する。テストは Fake を注入する。
protocol VideoRotationConnection: AnyObject {
    func isVideoRotationAngleSupported(_ videoRotationAngle: CGFloat) -> Bool
    var videoRotationAngle: CGFloat { get set }
    var isVideoMirroringSupported: Bool { get }
    var isVideoMirrored: Bool { get set }
}

extension AVCaptureConnection: VideoRotationConnection {}

/// 回転角サービスの単一シーム。`DeviceRotationService` が適合し、
/// テストでは `FakeDeviceRotationService` が適合する。
/// 起停・再生成の指示口と両角の配信口を一本化したもの
/// （旧 `SessionRotationService`／`SessionRotationAngleSource`／
/// `PreviewRotationAngleSource` の統合。適合クラスは当初から1つのみだった）。
protocol DeviceRotationServiceProtocol: AnyObject {
    /// preview 用回転角（度）。KVO 由来の本番ではメイン配送される。
    var previewRotationAngle: CGFloat { get }
    /// capture 用回転角（度）。KVO 由来の本番ではメイン配送される。
    var captureRotationAngle: CGFloat { get }
    /// preview 角の配信。View が同一インスタンスを購読する。
    var previewRotationAnglePublisher: AnyPublisher<CGFloat, Never> { get }
    /// capture 角の配信。Session が同一インスタンスを購読する。
    /// Session は preview 角を使わないため結合配信は持たない。
    var captureRotationAnglePublisher: AnyPublisher<CGFloat, Never> { get }
    /// 監視・校正開始時に呼ばれる（Motion 起停と同一則）。
    func start()
    /// 停止・背景移行時に呼ばれる（Motion 起停と同一則）。
    func stop()
    /// カメラ確定時・プレビュー層出現時に Session が呼ぶ再生成。
    func recreate(for device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer?)
}

enum CameraPosition: String, Codable, Equatable {
    case front
    case back
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
    /// 近傍側の耳-肩距離（Vision 正規化座標系、単位の基準なし）。前出し検出の第2指標。
    var nearDistance: Double
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
}

enum DisplayedPosture: Equatable {
    case good
    case slouch
    case personMissing
}

enum CalibrationProgress: Equatable {
    case waitingForPerson
    case accumulating(elapsed: TimeInterval)
    case completed(referenceNearAngleDegrees: Double, referenceDistance: Double, referenceSide: Side, referencePoints: [CGPoint], referenceSource: ReferenceVectorSource)
}

/// 重力基準ベクトル（単位ベクトル相当の2次元ベクトル）。
/// 判定・校正・表示で同一の基準線を共有するための型。SIMD2<Double> の別名。
/// 不変条件は単位長（長さ 1±1e-9）。design.md "Data Models" 参照。
typealias ReferenceVector = SIMD2<Double>

/// 基準ベクトルの解決元（校正整合性のために追跡）。
enum ReferenceVectorSource: Equatable {
    case gravity          // MotionService からの重力
    case shoulderLine     // 両肩ライン直交
    case imageVertical    // 画像垂直 (0, 1) フォールバック
}

/// 基準ベクトルとその解決元をセットで扱う（Comment 1 対策: 校正値の整合性確保）。
struct ResolvedReferenceVector: Equatable {
    let vector: ReferenceVector
    let source: ReferenceVectorSource
}

/// 距離指標の評価に必要データ（Session 層が校正完了時に構成し監視中保持・FQ1）。
struct DistanceMetric: Equatable {
    var side: Side                // 校正時にロックした側
    var referenceDistance: Double // 校正時耳-肩距離の平均（正規化座標系）
}

struct SessionSnapshot: Equatable {
    var phase: SessionPhase = .awaitingPermission
    var displayedPosture: DisplayedPosture = .good
    var isDimmed: Bool = false
    var isPersonDetected: Bool = false
    /// 人物は映っているが肩のキーポイントが読めない状態（顔のみ検出）。
    /// 校正中の「肩が映っていません」案内に使用。
    var isShoulderMissing: Bool = false
    var slouchGate: TimedConditionGate = TimedConditionGate(requiredDuration: 3.0)
    var calibrationProgress: CalibrationProgress = .waitingForPerson
    var referenceAngle: Double? = nil
    /// 校正時耳-肩距離の平均（正規化座標系）。ロック側の基準距離。
    var referenceDistance: Double? = nil
    /// 校正時にロックした側（FQ1）。監視中の距離評価はこの側の耳-肩ペアで行う。
    var referenceSide: Side? = nil
    var referencePoints: [CGPoint]? = nil
    var visualizationPoints: [CGPoint] = []
    /// キャプチャ画像のアスペクト比（バッファ実寸から算出）。可視化のクロップ補正に使用。
    var videoAspectRatio: CGFloat = 4.0 / 3.0
    var nearSide: Side? = nil
    /// 判定が返した基準線ベクトル（表示専用、非オプショナル）。
    /// Vision座標系（y上向き）の方向ベクトルをそのまま保持する（単一解決）。
    /// 初期値・プレビューはダミー垂直 (0,1)。判定には影響しない。
    var referenceVector: CGVector = CGVector(dx: 0, dy: 1)
    /// 校正時に使用された基準ベクトルの解決元（Comment 1 対策: 校正値の整合性確保）。
    /// 監視中に解決元が変わった場合、再校正をトリガーする。
    var calibrationReferenceSource: ReferenceVectorSource? = nil
    /// 現在の端末向きがランドスケープか（なで肩ガイダンスの分岐に使用。ADR 0014）。
    var isLandscape: Bool = false
    
    // MARK: - 閾値ガイド表示用（スライダー操作中のみ使用）
    
    /// 近側耳→肩ベクトル（Vision正規化座標系、正規化済み）。ガイド線の方向決定に使用。
    var earShoulderVector: CGVector = .zero
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
