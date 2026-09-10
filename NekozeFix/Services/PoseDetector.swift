import Vision
import QuartzCore

/// Vision ベースの人体ポーズキーポイント抽出。
///
/// VNDetectHumanBodyPoseRequest を用いてキーポイントを抽出し、
/// 信頼度閾値 (0.5) でフィルタリング、空の観測結果 (personMissing) の場合は
/// nil を返します。
///
/// 設計参照: design.md の "PoseDetector" セクション。
final class PoseDetector: @unchecked Sendable {
    // MARK: - プロパティ

    private var request: VNDetectHumanBodyPoseRequest
    private let visionQueue = DispatchQueue(label: "com.nekozefix.vision.queue")

    // MARK: - 初期化

    init() {
        self.request = VNDetectHumanBodyPoseRequest()
        // VNDetectHumanBodyPoseRequestRevision1 は iOS 14.0 から利用可
        // iOS 16.0+ 互換のためデフォルトリビジョン使用
    }

    // MARK: - 検出

    func detect(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) -> PoseFrame? {
        var result: PoseFrame?

        let semaphore = DispatchSemaphore(value: 0)

        let detectionRequest = VNDetectHumanBodyPoseRequest { [weak self] request, error in
            defer { semaphore.signal() }

            guard error == nil else {
                return
            }

            guard let observation = request.results?.first as? VNHumanBodyPoseObservation else {
                // 空の観測結果: nil は personMissing を示す
                result = nil
                return
            }

            result = self?.extractPoseFrame(from: observation)
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: CMSampleBufferGetImageBuffer(sampleBuffer)!,
            orientation: orientation
        )

        do {
            try handler.perform([detectionRequest])
        } catch {
            return nil
        }

        semaphore.wait()
        return result
    }

    // MARK: - プライベートメソッド

    private func extractPoseFrame(from observation: VNHumanBodyPoseObservation) -> PoseFrame? {
        let keypointThreshold: Float = 0.3 // 0.5から0.3に緩和して検出率を向上

        func extractKeypoint(_ jointName: VNHumanBodyPoseObservation.JointName) -> Keypoint? {
            guard let point = try? observation.recognizedPoint(jointName),
                  point.confidence >= keypointThreshold else {
                return nil
            }
            return Keypoint(x: Double(point.location.x), y: Double(point.location.y), confidence: Double(point.confidence))
        }

        // キューのバックログ時は最新フレームのみをディスパッチ
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
