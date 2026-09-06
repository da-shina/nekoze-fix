import Vision

/// Vision ベースの人体ポーズキーポイント抽出。
///
/// VNDetectHumanBodyPoseRequest を用いてキーポイントを抽出し、
/// 信頼度閾値 (0.5) でフィルタリング、空の観測結果 (personMissing) の場合は
/// nil を返します。
///
/// 設計参照: design.md の "PoseDetector" セクション。
final class PoseDetector {
    // MARK: - プロパティ

    private let request = VNDetectHumanBodyPoseRequest()
    private let visionQueue = DispatchQueue(label: "com.nekozefix.vision.queue")

    // MARK: - 初期化

    init() {
        // VNDetectHumanBodyPoseRequestRevision1 は iOS 14.0 から利用可
        // iOS 16.0+ 互換のためデフォルトリビジョン使用
        request.revision = VNDetectHumanBodyPoseRequestRevision1
    }

    // MARK: - 検出

    func detect(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) -> PoseFrame? {
        var result: PoseFrame?

        let semaphore = DispatchSemaphore(value: 0)

        request = VNDetectHumanBodyPoseRequest { request, error in
            defer { semaphore.signal() }

            guard error == nil else {
                return
            }

            guard let observation = request.results?.first as? VNHumanBodyPoseObservation else {
                // 空の観測結果: nil は personMissing を示す
                result = nil
                return
            }

            let frame = self.extractPoseFrame(from: observation, orientation: orientation)
            result = frame
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: CMSampleBufferGetImageBuffer(sampleBuffer)!,
            orientation: orientation
        )

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        semaphore.wait()
        return result
    }

    // MARK: - プライベートメソッド

    private func extractPoseFrame(from observation: VNHumanBodyPoseObservation, orientation: CGImagePropertyOrientation) -> PoseFrame? {
        let keypointThreshold: Float = 0.5

        func extractKeypoint(_ key: VNHumanBodyPoseObservation.Key) -> Keypoint? {
            guard let point = try? observation.recognizedPoint(key),
                  observation.recognizedPoint(key, normalizationBox: CGRect(x: 0, y: 0, width: 1, height: 1)).confidence >= keypointThreshold else {
                return nil
            }
            return Keypoint(x: Double(point.x), y: Double(point.y), confidence: Double(observation.recognizedPoint(key).confidence))
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