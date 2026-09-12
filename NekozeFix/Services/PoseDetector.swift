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

    /// 画面中央 (0.5, 0.5) に最も近い boundingBox を持つ観測を1つ選ぶ。
    /// 複数人物が写っている場合の「認識する人物」の単一基準（design.md / FR 4.7）。
    /// boundingBox は VNObservation 基底には無く個別クラス側に定義されているため、
    /// 取得クロージャを渡す汎用実装にする。
    static func closestToCenter<T>(_ observations: [T], box: (T) -> CGRect) -> T? {
        observations.min { a, b in
            centerDistance(box(a)) < centerDistance(box(b))
        }
    }

    /// Body Pose 観測の有効キーポイントを囲む矩形（人物位置の代理 boundingBox）。
    /// VNHumanBodyPoseObservation には boundingBox が無いため、抽出済み
    /// PoseFrame のキーポイントから算出する。キーポイントが無ければ .zero。
    static func poseBoundingBox(_ frame: PoseFrame) -> CGRect {
        let points = [frame.leftEar, frame.rightEar, frame.leftShoulder, frame.rightShoulder]
            .compactMap { $0 }
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

    func detect(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) -> Detection {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return .absent
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)

        // パス1: 顔検出（人物の所在基準。複数人時は画面中央の顔を選ぶ）
        var faceBounds: CGRect?
        let faceSemaphore = DispatchSemaphore(value: 0)
        let faceRequest = VNDetectFaceRectanglesRequest { request, _ in
            defer { faceSemaphore.signal() }
            faceBounds = (request.results as? [VNFaceObservation])
                .flatMap { Self.closestToCenter($0, box: \.boundingBox) }?
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
            // 複数人時は画面中央の人物のみ認識（FR 4.7）。
            // VNHumanBodyPoseObservation に boundingBox は無いため、
            // 抽出済みキーポイントの囲み矩形を人物位置の代理として中央距離で選ぶ。
            let frames = (request.results as? [VNHumanBodyPoseObservation])?
                .compactMap { self.extractPoseFrame(from: $0) } ?? []
            guard let frame = Self.closestToCenter(frames, box: Self.poseBoundingBox) else {
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

        /// 閾値適用前の raw confidence（-1 = キーポイント未取得）。DEBUG 診断用。
        func rawConfidence(_ jointName: VNHumanBodyPoseObservation.JointName) -> Double {
            guard let point = try? observation.recognizedPoint(jointName) else { return -1 }
            return Double(point.confidence)
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
            rightShoulder: rightShoulder,
            rawLeftShoulderConfidence: rawConfidence(.leftShoulder),
            rawRightShoulderConfidence: rawConfidence(.rightShoulder),
            rawLeftEarConfidence: rawConfidence(.leftEar),
            rawRightEarConfidence: rawConfidence(.rightEar)
        )
    }
}
