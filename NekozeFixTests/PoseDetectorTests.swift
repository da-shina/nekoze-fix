import XCTest
import Vision
import CoreMedia
import QuartzCore
@testable import NekozeFix

final class PoseDetectorTests: XCTestCase {

    // MARK: - 中央人物選択の距離基準（FR 4.7）

    func testCenterDistance_prefersFrameCenter() {
        let centered = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)   // 中心 (0.5, 0.5)
        let offCenter = CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.2)  // 中心 (0.1, 0.1)
        XCTAssertLessThan(PoseDetector.centerDistance(centered),
                          PoseDetector.centerDistance(offCenter))
    }

    func testCenterDistance_symmetricEqualDistance() {
        let left = CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2)   // 中心 (0.2, 0.5)
        let right = CGRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2)  // 中心 (0.8, 0.5)
        XCTAssertEqual(PoseDetector.centerDistance(left),
                       PoseDetector.centerDistance(right), accuracy: 1e-9)
    }

    func testClosestToCenter_empty_returnsNil() {
        XCTAssertNil([CGRect]().min(by: { PoseDetector.centerDistance($0) < PoseDetector.centerDistance($1) }))
    }

    // MARK: - 向き別の信頼度閾値（要件4.6）

    func testConfidenceThreshold_portrait_isStrict() {
        XCTAssertEqual(keypointConfidenceThreshold(isLandscape: false), 0.3, accuracy: 1e-9)
    }

    func testConfidenceThreshold_landscape_isRelaxed() {
        XCTAssertEqual(keypointConfidenceThreshold(isLandscape: true), 0.1, accuracy: 1e-9)
    }

    // MARK: - 人物選択矩形は有効点のみで算出

    func testPoseBoundingBox_ignoresLowConfidenceOutliers() {
        // 前提: 中心人物の高信頼度3点＋離れた低信頼度1点
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.45, y: 0.5, confidence: 0.9),
            rightEar: Keypoint(x: 0.55, y: 0.5, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.45, y: 0.7, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.05, y: 0.1, confidence: 0.1)
        )

        // 検証: 外れ値を除いた矩形になる
        let box = PoseDetector.poseBoundingBox(frame)
        XCTAssertEqual(box.minX, 0.45, accuracy: 1e-9)
        XCTAssertEqual(box.maxX, 0.55, accuracy: 1e-9)
    }

    // MARK: - 条件付き顔検出の合成則（ADR 0021、tasks 2.1）

    func testSynthesize_poseWinsRegardlessOfFace() {
        // Q2確定：観測あり（4点全 nil を含む）は顔有無にかかわらず成功経路（.pose）のままであること
        let frame = PoseFrame(timestamp: 0, leftEar: nil, rightEar: nil, leftShoulder: nil, rightShoulder: nil)
        for faceBounds in [CGRect(x: 0, y: 0, width: 1, height: 1), nil] {
            let result = PoseDetector.synthesize(pose: .pose(frame), faceBounds: faceBounds)
            guard case .pose = result else {
                return XCTFail("姿勢観測ありは顔有無にかかわらず .pose を返すこと")
            }
        }
    }

    func testSynthesize_faceOnlyBecomesPersonOnly() {
        let result = PoseDetector.synthesize(pose: nil, faceBounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        guard case .personOnly = result else {
            return XCTFail("姿勢なし・顔ありは .personOnly であること")
        }
    }

    func testSynthesize_noPoseNoFaceBecomesAbsent() {
        let result = PoseDetector.synthesize(pose: nil, faceBounds: nil)
        guard case .absent = result else {
            return XCTFail("両方なしは .absent であること")
        }
    }

    // MARK: - 推論計測器（tasks 1.3 / 2.1）

    func testMetrics_initialStateIsZero() {
        XCTAssertEqual(PoseDetector().snapshot(), PoseDetector.Metrics())
    }

    func testMetrics_resetRestoresZero() throws {
        // 前提: 無効バッファ検出（計数不変）→ reset → 初期値に戻ること
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        guard status == noErr, let buffer = sb else {
            throw NSError(domain: "PoseDetectorTests", code: 1)
        }
        let detector = PoseDetector()
        let tracker = ProlongedAbsenceTracker()
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)
        detector.reset()
        XCTAssertEqual(detector.snapshot(), PoseDetector.Metrics())
    }

    func testDetect_invalidBufferReturnsAbsentWithoutCounting() throws {
        // 前提: 画像を含まないサンプルバッファ（Visionに触れずガードで不在を返す）
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        guard status == noErr, let buffer = sb else {
            throw NSError(domain: "PoseDetectorTests", code: 1)
        }

        let detector = PoseDetector()
        let tracker = ProlongedAbsenceTracker()
        let result = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)

        guard case .absent = result else {
            return XCTFail("無効バッファは .absent であること")
        }
        XCTAssertEqual(detector.snapshot(), PoseDetector.Metrics(), "無効バッファでは計数が進まないこと")
    }

    // 注意: 成功経路・失敗経路の実推論による計数進行は実機で検証する（tasks 3.1）。
    // シミュレータでは VNDetectHumanBodyPoseRequest の setup 自体が
    // Code=9 で失敗するため、ここでは合成則と計測器の単体検証に留める。

    // MARK: - 顔フォールバック間引き（absent-vision-reduction）

    /// 長時間不在中かつ姿勢観測ゼロ件時、間引き間隔内は顔スキップ（.absent 返却、faceThrottledCount++）。
    func testDetect_prolongedAbsence_throttlesFaceFallback() throws {
        let detector = PoseDetector()
        let tracker = ProlongedAbsenceTracker(absentThreshold: 0.1, faceFallbackThrottleInterval: 5.0)
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        guard status == noErr, let buffer = sb else {
            throw NSError(domain: "PoseDetectorTests", code: 1)
        }

        // 長時間不在状態にする（閾値 0.1s なので即遷移）
        _ = tracker.tick(isPersonDetected: false, now: 1000)
        _ = tracker.tick(isPersonDetected: false, now: 1001)
        XCTAssertTrue(tracker.isProlongedAbsence)

        // 最初の顔実行は実行される（間引き判定 true）
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)
        let metrics1 = detector.snapshot()
        XCTAssertEqual(metrics1.faceExecutedCount, 1)
        XCTAssertEqual(metrics1.faceThrottledCount, 0)

        // 間引き間隔内（5秒）はスキップされる
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)
        let metrics2 = detector.snapshot()
        XCTAssertEqual(metrics2.faceExecutedCount, 1, "間引き間隔内は顔実行されない")
        XCTAssertEqual(metrics2.faceThrottledCount, 2, "間引きでスキップされた回数が計数される")
        XCTAssertEqual(metrics2.faceSkippedCount, 0, "姿勢観測あり時のみ faceSkippedCount が増える")
    }

    /// 長時間不在でない場合、毎回顔フォールバックが実行される（faceExecutedCount インクリメント）。
    func testDetect_notProlongedAbsence_executesFaceFallbackEveryTime() throws {
        let detector = PoseDetector()
        let tracker = ProlongedAbsenceTracker()
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        guard status == noErr, let buffer = sb else {
            throw NSError(domain: "PoseDetectorTests", code: 1)
        }

        // 長時間不在でない状態
        XCTAssertFalse(tracker.isProlongedAbsence)

        // 無効バッファでは .absent が返るが、間引き判定は true（実行済みとして記録される）
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)

        let metrics = detector.snapshot()
        // 無効バッファでも間引き判定は毎回 true が返るため faceExecutedCount が増える
        // （実際の Vision 実行は失敗するが、間引き判定のロジックは通る）
        XCTAssertEqual(metrics.faceExecutedCount, 3)
        XCTAssertEqual(metrics.faceThrottledCount, 0)
    }

    /// Metrics 計数: faceThrottledCount / faceExecutedCount / faceSkippedCount / faceTotalTime / poseTotalTime
    func testMetrics_throttlingCountsAllMetrics() throws {
        let detector = PoseDetector()
        let tracker = ProlongedAbsenceTracker(absentThreshold: 0.1, faceFallbackThrottleInterval: 5.0)
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        guard status == noErr, let buffer = sb else {
            throw NSError(domain: "PoseDetectorTests", code: 1)
        }

        _ = tracker.tick(isPersonDetected: false, now: 1000)
        _ = tracker.tick(isPersonDetected: false, now: 1001)

        // 1回実行、2回間引き
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)

        let metrics = detector.snapshot()
        XCTAssertEqual(metrics.faceExecutedCount, 1)
        XCTAssertEqual(metrics.faceThrottledCount, 2)
        XCTAssertEqual(metrics.faceSkippedCount, 0)
        XCTAssertGreaterThan(metrics.poseTotalTime, 0)
        XCTAssertGreaterThanOrEqual(metrics.faceTotalTime, 0)
    }

    /// 長時間不在解除後（Tracker リセット後）は毎回実行に復帰する。
    func testDetect_afterProlongedAbsenceReset_executesEveryTime() throws {
        let detector = PoseDetector()
        let tracker = ProlongedAbsenceTracker(absentThreshold: 0.1, faceFallbackThrottleInterval: 5.0)
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        guard status == noErr, let buffer = sb else {
            throw NSError(domain: "PoseDetectorTests", code: 1)
        }

        // 長時間不在状態にする
        _ = tracker.tick(isPersonDetected: false, now: 1000)
        _ = tracker.tick(isPersonDetected: false, now: 1001)
        XCTAssertTrue(tracker.isProlongedAbsence)

        // 1回実行
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)

        // リセット（長時間不在解除相当）
        tracker.reset()
        XCTAssertFalse(tracker.isProlongedAbsence)

        // リセット後は毎回実行
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)
        _ = detector.detect(sampleBuffer: buffer, orientation: .up, prolongedAbsenceTracker: tracker)

        let metrics = detector.snapshot()
        XCTAssertEqual(metrics.faceExecutedCount, 3) // 初回 + リセット後2回
        XCTAssertEqual(metrics.faceThrottledCount, 0)
    }

    /// 合成則不変: synthesize 既存テストで回帰確認（姿勢優先、顔有無の順序）
    func testSynthesize_invariance_withThrottling() {
        // 間引き導入前後で合成則が変わらないことを確認
        let frame = PoseFrame(timestamp: 0, leftEar: nil, rightEar: nil, leftShoulder: nil, rightShoulder: nil)

        // 姿勢観測あり（4点全 nil）は顔有無にかかわらず .pose
        for faceBounds in [CGRect(x: 0, y: 0, width: 1, height: 1), nil as CGRect?] {
            let result = PoseDetector.synthesize(pose: .pose(frame), faceBounds: faceBounds)
            guard case .pose = result else {
                return XCTFail("姿勢観測ありは顔有無にかかわらず .pose を返すこと")
            }
        }

        // 姿勢なし・顔ありは .personOnly
        let resultFace = PoseDetector.synthesize(pose: nil, faceBounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        guard case .personOnly = resultFace else {
            return XCTFail("姿勢なし・顔ありは .personOnly であること")
        }

        // 両方なしは .absent
        let resultAbsent = PoseDetector.synthesize(pose: nil, faceBounds: nil)
        guard case .absent = resultAbsent else {
            return XCTFail("両方なしは .absent であること")
        }
    }
}
