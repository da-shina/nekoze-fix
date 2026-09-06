import Vision

/// Vision-based body pose keypoint extraction.
///
/// Uses VNDetectHumanBodyPoseRequest to extract keypoints,
/// filters by confidence threshold (0.5), and returns nil
/// for empty observations (personMissing).
///
/// Design ref: design.md "PoseDetector" section.
final class PoseDetector {
    // MARK: - Properties

    private let request = VNDetectHumanBodyPoseRequest()
    private let visionQueue = DispatchQueue(label: "com.nekozefix.vision.queue")

    // MARK: - Initialization

    init() {
        // VNDetectHumanBodyPoseRequestRevision1 is available from iOS 14.0
        // Use default revision for iOS 16.0+ compatibility
        request.revision = VNDetectHumanBodyPoseRequestRevision1
    }

    // MARK: - Detection

    func detect(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) -> PoseFrame? {
        var result: PoseFrame?

        let semaphore = DispatchSemaphore(value: 0)

        request = VNDetectHumanBodyPoseRequest { request, error in
            defer { semaphore.signal() }

            guard error == nil else {
                return
            }

            guard let observation = request.results?.first as? VNHumanBodyPoseObservation else {
                // Empty observation: nil indicates personMissing
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

    // MARK: - Private Methods

    private func extractPoseFrame(from observation: VNHumanBodyPoseObservation, orientation: CGImagePropertyOrientation) -> PoseFrame? {
        let keypointThreshold: Float = 0.5

        func extractKeypoint(_ key: VNHumanBodyPoseObservation.Key) -> Keypoint? {
            guard let point = try? observation.recognizedPoint(key),
                  observation.recognizedPoint(key, normalizationBox: CGRect(x: 0, y: 0, width: 1, height: 1)).confidence >= keypointThreshold else {
                return nil
            }
            return Keypoint(x: Double(point.x), y: Double(point.y), confidence: Double(observation.recognizedPoint(key).confidence))
        }

        // Latest-frame-only dispatch when queue backlogged
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