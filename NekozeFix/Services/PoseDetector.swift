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

    private let visionQueue = DispatchQueue(label: "com.nekozefix.vision.queue")

    // MARK: - 検出

    func detect(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) -> Detection {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return .absent
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)

        // パス1: 顔検出（人物の所在と規模の基準）
        var faceBounds: CGRect?
        let faceSemaphore = DispatchSemaphore(value: 0)
        let faceRequest = VNDetectFaceRectanglesRequest { request, _ in
            defer { faceSemaphore.signal() }
            faceBounds = (request.results as? [VNFaceObservation])?
                .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })?
                .boundingBox
        }
        do {
            try handler.perform([faceRequest])
        } catch {
            print("Vision Handler Error (face): \(error)")
            return .absent
        }
        faceSemaphore.wait()

        // パス2: Body Pose（フルフレーム。顔周囲 ROI を与えると人体全体像を
        // 認識できず観測が空になるため使わない）
        var poseResult: Detection?
        let poseSemaphore = DispatchSemaphore(value: 0)
        let poseRequest = VNDetectHumanBodyPoseRequest { request, error in
            defer { poseSemaphore.signal() }
            if let error = error {
                print("Vision Error: \(error)")
                return
            }
            guard let observation = request.results?.first as? VNHumanBodyPoseObservation,
                  let frame = self.extractPoseFrame(from: observation) else {
                return
            }
            poseResult = .pose(frame)
        }

        do {
            try handler.perform([poseRequest])
        } catch {
            print("Vision Handler Error (pose): \(error)")
        }
        poseSemaphore.wait()

        // Body Pose でキーポイントが取れなくても、顔が映っていれば人物あり
        // （接写で俯いた際など、Body Pose 観測が空になるケースのフォールバック）
        return poseResult ?? (faceBounds != nil ? .personOnly : .absent)
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
