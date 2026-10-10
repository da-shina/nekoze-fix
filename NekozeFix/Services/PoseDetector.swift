import Foundation
import Vision
import QuartzCore

/// Vision ベースの人体ポーズキーポイント抽出。
///
/// VNDetectHumanBodyPoseRequest でキーポイントを抽出する。
/// 人物検出の有無は Body Pose 観測 **または** 顔検出のいずれかで判定する:
/// 前面カメラ接写で頭を下げると（猫背姿勢そのもの）Body Pose の観測が
/// 空になる実測結果を受け、顔のフォールバックを追加した（2026-09-12）。
/// 顔のみ検出の場合は全キーポイントが nil の PoseFrame を返す
/// （= 人物はいるが角度は計算できない）。
///
/// 設計参照: design.md の "PoseDetector" セクション。
final class PoseDetector: @unchecked Sendable {
    // MARK: - 検出結果

    enum Detection {
        case pose(PoseFrame)   // 人物検出 + キーポイントあり
        case personOnly        // 顔のみ等、人物はいるがキーポイントなし
        case absent            // 人物なし
    }

    // MARK: - プロパティ

    /// 推論回数・推論時間の計測値（プロセス内メモリのみ、永続化・送出なし）。
    /// 成功経路＝顔省略、失敗経路＝顔実行を区別して数える。
    /// `detect` は detectionQueue 上で同期実行されるため錠で保護する。
    struct Metrics: Equatable {
        var faceSkippedCount = 0
        var faceExecutedCount = 0
        var poseTotalTime: Double = 0
        var faceTotalTime: Double = 0
    }

    private let metricsLock = NSLock()
    private var _metrics = Metrics()

    /// 計測値の複写を返す。検出結果には影響しない。
    func snapshot() -> Metrics {
        metricsLock.withLock { _metrics }
    }

    /// 計測値を初期化する（実機計測の区切り用）。
    func reset() {
        metricsLock.withLock { _metrics = Metrics() }
    }

    // MARK: - 検出

    /// Body Pose 観測の有効キーポイントを囲む矩形（人物位置の代理 boundingBox）。
    /// VNHumanBodyPoseObservation には boundingBox が無いため、抽出済み
    /// PoseFrame のキーポイントから算出する。人物選択用に信頼度 0.3 以上の点のみで
    /// 算出する（検出層の足切りなし方針とは独立。低信頼度の外れ値が複数人時の
    /// 中央判定をずらすのを防ぐ）。キーポイントが無ければ .zero。
    static func poseBoundingBox(_ frame: PoseFrame) -> CGRect {
        let points = [frame.leftEar, frame.rightEar, frame.leftShoulder, frame.rightShoulder]
            .compactMap { $0 }
            .filter { $0.confidence >= minimumKeypointConfidence }
            .map { CGPoint(x: $0.x, y: $0.y) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 中心のユークリッド距離の二乗（比較専用なので sqrt は省く）
    static func centerDistance(_ box: CGRect) -> CGFloat {
        let dx = box.midX - 0.5
        let dy = box.midY - 0.5
        return dx * dx + dy * dy
    }

    /// 姿勢結果と顔有無の合成則（現行と同一：姿勢優先、次に顔有無）。
    /// 条件実行の前後で意味が変わらないことの検証点をここに隔離する。
    /// 観測あり・4点全 nil の PoseFrame も `.pose` のまま返す（ADR 0021 Q2）。
    static func synthesize(pose: Detection?, faceBounds: CGRect?) -> Detection {
        pose ?? (faceBounds != nil ? .personOnly : .absent)
    }

    func detect(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) -> Detection {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return .absent
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)

        // パス1: 姿勢検出のみ先行実行する。観測の有無だけで顔フェーズへの分岐を決め、
        // 信頼度や点数は持ち込まない（ADR 0021）。現行合成式と同一の出力を保証する。
        var poseResult: Detection?
        let poseRequest = VNDetectHumanBodyPoseRequest { request, error in
            if let error = error {
                print("Vision Error: \(error)")
                return
            }
            // 複数人時は画面中央の人物のみ認識（FR 4.7）。
            // VNHumanBodyPoseObservation に boundingBox は無いため、
            // 抽出済みキーポイントの囲み矩形を人物位置の代理として中央距離で選ぶ。
            // 検出層は認識できた点をすべて保持する（足切りなし）。
            // 向き別の信頼度フィルタは Session 層（processDetection・MainActor）が
            // snapshot.isLandscape を見て適用する。検出キューから snapshot を
            // 読むとアクタ境界をまたぐため、方針判断は MainActor 側に寄せる。
            let frames = (request.results as? [VNHumanBodyPoseObservation])?
                .compactMap { self.extractPoseFrame(from: $0, minimumConfidence: 0) } ?? []
            guard let frame = frames.min(by: { Self.centerDistance(Self.poseBoundingBox($0)) < Self.centerDistance(Self.poseBoundingBox($1)) }) else {
                return
            }
            poseResult = .pose(frame)
        }

        let poseStart = CACurrentMediaTime()
        do {
            try handler.perform([poseRequest])
        } catch {
            print("Vision Handler Error: \(error)")
            return .absent
        }
        let poseElapsed = CACurrentMediaTime() - poseStart
        metricsLock.withLock { _metrics.poseTotalTime += poseElapsed }

        // 姿勢観測あり（4点全 nil の PoseFrame を含む）は顔推論を省略して確定する。
        // Body Pose でキーポイントが取れなくても、顔が映っていれば人物あり
        // （接写で俯いた際など、Body Pose 観測が空になるケースのフォールバック）
        // の判定は観測ゼロ件時のみ顔フェーズで行う。
        if let pose = poseResult {
            metricsLock.withLock { _metrics.faceSkippedCount += 1 }
            return pose
        }

        // パス2: 観測ゼロ件時のみ顔検出（人物の所在基準。複数人時は画面中央の顔を選ぶ）
        var faceBounds: CGRect?
        let faceRequest = VNDetectFaceRectanglesRequest { request, _ in
            faceBounds = (request.results as? [VNFaceObservation])?
                .min(by: { Self.centerDistance($0.boundingBox) < Self.centerDistance($1.boundingBox) })?
                .boundingBox
        }

        let faceStart = CACurrentMediaTime()
        do {
            try handler.perform([faceRequest])
        } catch {
            print("Vision Handler Error: \(error)")
            return .absent
        }
        let faceElapsed = CACurrentMediaTime() - faceStart
        metricsLock.withLock {
            _metrics.faceExecutedCount += 1
            _metrics.faceTotalTime += faceElapsed
        }

        return Self.synthesize(pose: nil, faceBounds: faceBounds)
    }

    // MARK: - プライベートメソッド

    private func extractPoseFrame(from observation: VNHumanBodyPoseObservation, minimumConfidence: Double) -> PoseFrame? {
        func extractKeypoint(_ jointName: VNHumanBodyPoseObservation.JointName) -> Keypoint? {
            guard let point = try? observation.recognizedPoint(jointName),
                  point.confidence >= Float(minimumConfidence) else {
                return nil
            }
            return Keypoint(x: Double(point.location.x), y: Double(point.location.y), confidence: Double(point.confidence))
        }

        let leftEar = extractKeypoint(.leftEar)
        let rightEar = extractKeypoint(.rightEar)
        let leftShoulder = extractKeypoint(.leftShoulder)
        let rightShoulder = extractKeypoint(.rightShoulder)

        return PoseFrame(
            timestamp: CACurrentMediaTime(),
            leftEar: leftEar,
            rightEar: rightEar,
            leftShoulder: leftShoulder,
            rightShoulder: rightShoulder
        )
    }
}
