import Foundation

struct PostureAnalyzer {
    /// Analyzes a pose frame to determine slouch status.
    ///
    /// Near-side selection: when both sides are valid, the shoulder with the
    /// smaller x-coordinate is the near-side (Q9). When only one side is
    /// valid, that side is automatically the near-side (Q11).
    ///
    /// Angle calculation: vector from shoulder to ear vs. vertical (0,1).
    /// Result is acute 0-90 degrees. No moving average filter (Q12).
    ///
    /// Confidence < 0.5 keypoints are filtered out (4.5).
    /// Camera mount angle is absorbed in the reference value.
    func analyze(
        frame: PoseFrame,
        referenceNearAngleDegrees: Double?,
        slouchDeltaThresholdDegrees: Double
    ) -> (sample: AngleSample?, verdict: PostureVerdict) {

        // Step 1: Identify valid keypoint pairs on each side (confidence >= 0.5)
        let leftValid = isValidPair(ear: frame.leftEar, shoulder: frame.leftShoulder)
        let rightValid = isValidPair(ear: frame.rightEar, shoulder: frame.rightShoulder)

        // Step 2: Determine near-side selection
        // - Both valid: compare shoulder x-coordinates (Q9)
        // - One valid: detected side is near-side (Q11)
        // - None valid: insufficient keypoints
        var nearSide: Side?
        var nearEar: Keypoint?
        var nearShoulder: Keypoint?
        var farSideDetected = false

        if leftValid && rightValid {
            // Both sides valid: select near-side by shoulder x-coordinate
            let lx = frame.leftShoulder!.x
            let rx = frame.rightShoulder!.x
            if lx < rx {
                nearSide = .left
                nearEar = frame.leftEar
                nearShoulder = frame.leftShoulder
                farSideDetected = true
            } else if rx < lx {
                nearSide = .right
                nearEar = frame.rightEar
                nearShoulder = frame.rightShoulder
                farSideDetected = true
            } else {
                // Equal x: default to left (Q9)
                nearSide = .left
                nearEar = frame.leftEar
                nearShoulder = frame.leftShoulder
                farSideDetected = true
            }
        } else if leftValid {
            // Only left side valid: auto-treat as near-side (Q11)
            nearSide = .left
            nearEar = frame.leftEar
            nearShoulder = frame.leftShoulder
            farSideDetected = false
        } else if rightValid {
            // Only right side valid: auto-treat as near-side (Q11)
            nearSide = .right
            nearEar = frame.rightEar
            nearShoulder = frame.rightShoulder
            farSideDetected = false
        } else {
            // No valid keypoints
            return (nil, .insufficientKeypoints)
        }

        // Step 3: Calculate acute angle (0-90 degrees)
        // Vector from shoulder to ear: v = (ear.x - shoulder.x, ear.y - shoulder.y)
        // cos(θ) = v · (0,1) / |v| = v.y / |v|
        // θ = acos(clamp(v.y / |v|, -1, 1))
        // Result is acute (Q10)
        let vx = nearEar!.x - nearShoulder!.x
        let vy = nearEar!.y - nearShoulder!.y
        let length = sqrt(vx * vx + vy * vy)
        guard length > 0 else { return (nil, .insufficientKeypoints) }

        let cosTheta = vy / length
        let clampedCos = max(-1.0, min(1.0, cosTheta))
        let thetaRadians = acos(clampedCos)
        let thetaDegrees = thetaRadians * 180.0 / .pi
        let acuteAngle = min(thetaDegrees, 180.0 - thetaDegrees)  // Ensure acute

        // Step 4: Determine verdict
        // Camera mount angle is absorbed in reference value.
        // No absolute vertical comparison.
        let referenceAngle = referenceNearAngleDegrees ?? 0.0
        let delta = acuteAngle - referenceAngle
        let verdict: PostureVerdict = delta >= slouchDeltaThresholdDegrees ? .slouchCandidate : .good

        return (
            AngleSample(
                nearSide: nearSide!,
                nearAngleDegrees: acuteAngle,
                farSideDetected: farSideDetected
            ),
            verdict
        )
    }

    /// Returns true when both ear and shoulder keypoints exist and pass
    /// confidence threshold.
    private func isValidPair(ear: Keypoint?, shoulder: Keypoint?) -> Bool {
        guard let ear = ear,
              let shoulder = shoulder,
              ear.confidence >= minimumKeypointConfidence,
              shoulder.confidence >= minimumKeypointConfidence
        else {
            return false
        }
        return true
    }
}