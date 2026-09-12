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

        guard let face = faceBounds else {
            return .absent
        }

        // パス2: 顔周囲を ROI として Body Pose（人物を拡大して見せ、
        // 低アングルでの肩の検出率を上げる）。顔の下に肩が来るよう範囲を取る。
        // Vision 正規化座標は左下原点なので「下」= y 減少方向。
        var poseResult: Detection = .personOnly
        let poseSemaphore = DispatchSemaphore(value: 0)
        // ROI: 横幅 2 倍、縦は顔高さの 3 倍（上 0.5 / 下 2.5）に拡張。
        // 範囲外 ROI は Vision がエラーを返し検出が全滅するため [0,1] にクランプする。
        let rawMinX = face.midX - face.width
        let rawMinY = face.minY - face.height * 2.5
        let rawMaxX = face.midX + face.width
        let rawMaxY = face.minY + face.height * 3.5
        let clampedRoi = CGRect(
            x: min(max(rawMinX, 0), 1),
            y: min(max(rawMinY, 0), 1),
            width: max(min(rawMaxX, 1) - max(rawMinX, 0), 0.01),
            height: max(min(rawMaxY, 1) - max(rawMinY, 0), 0.01)
        )
        let poseRequest = VNDetectHumanBodyPoseRequest { request, error in
            defer { poseSemaphore.signal() }
            if let error = error {
                print("Vision Error: \(error)")
                return
            }
            guard let observation = request.results?.first as? VNHumanBodyPoseObservation,
                  let frame = self.extractPoseFrame(from: observation, roi: clampedRoi) else {
                return
            }
            poseResult = .pose(frame)
        }
        poseRequest.regionOfInterest = clampedRoi

        do {
            try handler.perform([poseRequest])
        } catch {
            print("Vision Handler Error (pose): \(error)")
        }
        poseSemaphore.wait()

        return poseResult
    }

    // MARK: - プライベートメソッド

    /// ROI を使った観測の座標は ROI 基準の正規化座標で返されるため、
    /// 全画像座標 (0-1) へ写像し直す。
    private func extractPoseFrame(from observation: VNHumanBodyPoseObservation, roi: CGRect) -> PoseFrame? {
        let keypointThreshold: Float = 0.3 // 0.5から0.3に緩和して検出率を向上

        func extractKeypoint(_ jointName: VNHumanBodyPoseObservation.JointName) -> Keypoint? {
            guard let point = try? observation.recognizedPoint(jointName),
                  point.confidence >= keypointThreshold else {
                return nil
            }
            let x = roi.minX + Double(point.location.x) * roi.width
            let y = roi.minY + Double(point.location.y) * roi.height
            return Keypoint(x: x, y: y, confidence: Double(point.confidence))
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
