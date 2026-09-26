import XCTest
import AVFoundation
import Vision
@testable import NekozeFix

final class PerformanceTests: XCTestCase {

    // MARK: - Throughput Test (NFR 8.1)

    func testDetectionThroughput() {
        let detector = PoseDetector()
        let frameCount = 100

        guard let pixelBuffer = createDummyPixelBuffer() else {
            XCTFail("Failed to create dummy pixel buffer")
            return
        }

        let startTime = CACurrentMediaTime()
        for _ in 0..<frameCount {
            _ = detector.detect(pixelBuffer: pixelBuffer, orientation: .up)
        }
        let endTime = CACurrentMediaTime()

        let totalTime = endTime - startTime
        let fps = Double(frameCount) / totalTime

        print("--- Throughput Result ---")
        print("Total time for \(frameCount) frames: \(String(format: "%.3f", totalTime))s")
        print("Measured FPS: \(String(format: "%.2f", fps))")

        XCTAssertGreaterThanOrEqual(fps, 15.0, "Detection throughput should be >= 15 fps")
    }

    // MARK: - Latency Test (NFR 8.2)

    func testNotificationLatency() async {
        let settings = SettingsStore()
        let manager = await PostureSessionManager(settingsStore: settings)

        // Inject Mock
        let mockPlayer = MockAlertPlayer()
        await MainActor.run {
            manager.alertPlayer = mockPlayer
        }

        // Setup monitoring state
        var testSnapshot = SessionSnapshot()
        testSnapshot.phase = .monitoring
        testSnapshot.referenceAngle = 10.0
        testSnapshot.postureDisplayGate = TimedConditionGate(requiredDuration: 0)
        testSnapshot.slouchGate = TimedConditionGate(requiredDuration: 0.1)

        await MainActor.run {
            manager.setTestSnapshot(testSnapshot)
        }

        // Trigger a slouch: Vector (0.1, -0.3) vs Vertical (0, 1)
        // angle = acos( (-0.3*1) / (sqrt(0.1^2 + 0.3^2) * 1) ) = acos(-0.3 / 0.316) = acos(-0.948) = 161 deg
        // Acute angle = 180 - 161 = 19 deg. 19 > 5 (default threshold).
        let slouchDetection = PoseDetector.Detection.pose(
            PoseFrame(
                timestamp: CACurrentMediaTime(),
                leftEar: Keypoint(x: 0.6, y: 0.5, confidence: 1.0),
                rightEar: nil,
                leftShoulder: Keypoint(x: 0.5, y: 0.8, confidence: 1.0),
                rightShoulder: nil
            )
        )

        let startTime = CACurrentMediaTime()

        // Feed frames until the gate fires
        var fired = false
        var iterations = 0
        while !fired && iterations < 100 {
            iterations += 1
            await MainActor.run {
                manager.processDetection(slouchDetection)
                if mockPlayer.startRepeatingCalledAt != nil {
                    fired = true
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        let triggerTime = mockPlayer.startRepeatingCalledAt ?? CACurrentMediaTime()
        let latency = triggerTime - startTime

        print("--- Latency Result ---")
        print("Latency from detection start to sound: \(String(format: "%.3f", latency))s")

        XCTAssertNotNil(mockPlayer.startRepeatingCalledAt, "Notification should have been triggered")
        XCTAssertLessThan(latency, 0.5, "Latency should be within 0.5s (including the test gate of 0.1s)")
    }

    // MARK: - Helpers

    private func createDummyPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let width = 1280
        let height = 720

        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as [String: Any]

        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        return pixelBuffer
    }
}

class MockAlertPlayer: AlertPlaying {
    var playOnceCalledAt: TimeInterval?
    var startRepeatingCalledAt: TimeInterval?

    func configureSession() throws {}

    func playOnce() {
        playOnceCalledAt = CACurrentMediaTime()
    }

    func startRepeating() {
        startRepeatingCalledAt = CACurrentMediaTime()
    }

    func stop() {}
}
