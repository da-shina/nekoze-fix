import XCTest
import Vision
import CoreMedia
import QuartzCore
@testable import NekozeFix

final class PoseDetectorTests: XCTestCase {

    // MARK: - 中央人物選択の距離基準(FR 4.7)

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

    // MARK: - 向き別の信頼度閾値(要件4.6)

    func testConfidenceThreshold_portrait_isStrict() {
        XCTAssertEqual(keypointConfidenceThreshold(isLandscape: false), 0.3, accuracy: 1e-9)
    }

    func testConfidenceThreshold_landscape_isRelaxed() {
        XCTAssertEqual(keypointConfidenceThreshold(isLandscape: true), 0.1, accuracy: 1e-9)
    }

    // MARK: - 人物選択矩形は有効点のみで算出

    func testPoseBoundingBox_ignoresLowConfidenceOutliers() {
        // 前提: 中心人物の高信頼度3点+離れた低信頼度1点
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

    // MARK: - 条件付き顔検出の合成則(ADR 0021、tasks 2.1)

    func testSynthesize_poseWinsRegardlessOfFace() {
        // Q2確定:観測あり(4点全 nil を含む)は顔有無にかかわらず成功経路(.pose)のままであること
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

    // MARK: - 推論計測器(tasks 1.3 / 2.1)

    func testMetrics_initialStateIsZero() {
        XCTAssertEqual(PoseDetector().snapshot(), PoseDetector.Metrics())
    }

    func testMetrics_resetRestoresZero() throws {
        // 前提: 無効バッファ検出(計数不変)→ reset → 初期値に戻ること
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
        // 前提: 画像を含まないサンプルバッファ(Visionに触れずガードで不在を返す)
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

    // MARK: - 顔フォールバック間引きの結線(tasks 9)

    /// 非長時間不在では毎回実行可となり、間引き計数は進まない。
    /// 実行時刻を記録しないのは意図した仕様（移行直後の初回実行を待たせないため）。
    func testEvaluateFaceFallbackGate_NotProlonged_ExecutesEveryTimeWithoutThrottling() {
        let detector = PoseDetector()
        let tracker = ProlongedAbsenceTracker()

        XCTAssertTrue(detector.evaluateFaceFallbackGate(now: 1000, tracker: tracker))
        XCTAssertTrue(detector.evaluateFaceFallbackGate(now: 1001, tracker: tracker))
        XCTAssertEqual(detector.snapshot().faceThrottledCount, 0)
        XCTAssertEqual(
            tracker.snapshot().lastFaceExecutionTime, -.infinity,
            "非長時間不在では実行時刻を記録せず、長時間不在移行直後の初回実行を許可する"
        )
    }

    /// 長時間不在中の間引き結線: 間引き時は計数し、実行可時は tracker へ実行時刻を記録する。
    /// 間引き間隔の境界値そのものは `ProlongedAbsenceTrackerTests` が検証するため、ここでは繰り返さない。
    func testEvaluateFaceFallbackGate_Prolonged_CountsAndRecords() {
        let detector = PoseDetector()
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        _ = tracker.tick(isPersonDetected: false, now: 1000)
        _ = tracker.tick(isPersonDetected: false, now: 1061)
        XCTAssertTrue(tracker.isProlongedAbsence)

        // 1回目は実行可: 計数は進まず、実行時刻が tracker に記録される(結線)
        let first = 1062.0
        XCTAssertTrue(detector.evaluateFaceFallbackGate(now: first, tracker: tracker))
        XCTAssertEqual(detector.snapshot().faceThrottledCount, 0)
        XCTAssertEqual(tracker.snapshot().lastFaceExecutionTime, first, accuracy: 1e-9)

        // 間隔内は間引き: 計数され、実行時刻は据え置き
        XCTAssertFalse(detector.evaluateFaceFallbackGate(now: first + 0.1, tracker: tracker))
        XCTAssertEqual(detector.snapshot().faceThrottledCount, 1)
        XCTAssertEqual(tracker.snapshot().lastFaceExecutionTime, first, accuracy: 1e-9, "間引き時は記録を更新しない")

        // 間隔経過後は再び実行可: 計数は据え置き、実行時刻が更新される
        let second = first + 5.0
        XCTAssertTrue(detector.evaluateFaceFallbackGate(now: second, tracker: tracker))
        XCTAssertEqual(detector.snapshot().faceThrottledCount, 1, "実行可では計数が進まない")
        XCTAssertEqual(tracker.snapshot().lastFaceExecutionTime, second, accuracy: 1e-9)
    }

    // 注意: 成功経路・失敗経路の実推論による計数進行は実機で検証する(tasks 3.1)。
    // シミュレータでは VNDetectHumanBodyPoseRequest の setup 自体が
    // Code=9 で失敗するため、ここでは合成則・計測器・間引き結線の単体検証に留める。
}
