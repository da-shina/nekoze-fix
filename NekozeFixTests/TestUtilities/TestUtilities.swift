import Foundation
import QuartzCore
import CoreMedia
import XCTest
@testable import NekozeFix

/// `ProlongedAbsenceTracker` 用のテストヘルパー。
/// 不正閾値・間隔注入、時間モック、スナップショット比較を提供する。
enum ProlongedAbsenceTrackerTestHelper {
    /// 既定の不在しきい値（DimPowerPolicy と同一）。
    static let defaultAbsentThreshold: TimeInterval = DimPowerPolicy.defaultAbsentThreshold
    /// 既定の顔フォールバック間引き間隔。
    static let defaultThrottleInterval: TimeInterval = 5.0

    /// 無効な閾値・間隔の組み合わせを生成する。
    static var invalidThresholds: [(TimeInterval, TimeInterval)] {
        [
            (.nan, defaultThrottleInterval),
            (-1, defaultThrottleInterval),
            (.infinity, defaultThrottleInterval),
            (defaultAbsentThreshold, .nan),
            (defaultAbsentThreshold, -1),
            (defaultAbsentThreshold, .infinity),
        ]
    }

    /// 時間モック用の固定時刻シーケンスを生成する。
    static func timeSequence(start: TimeInterval = 1000, step: TimeInterval = 1.0, count: Int) -> [TimeInterval] {
        (0..<count).map { start + TimeInterval($0) * step }
    }

    /// スナップショットの主要フィールドを比較する（時刻フィールドは許容誤差付き）。
    static func assertSnapshotEqual(
        _ lhs: ProlongedAbsenceTracker.Snapshot,
        _ rhs: ProlongedAbsenceTracker.Snapshot,
        timeAccuracy: TimeInterval = 1e-9,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.isProlongedAbsence, rhs.isProlongedAbsence, file: file, line: line)
        if let ls = lhs.absenceStart, let rs = rhs.absenceStart {
            XCTAssertEqual(ls, rs, accuracy: timeAccuracy, file: file, line: line)
        } else {
            XCTAssertEqual(lhs.absenceStart, rhs.absenceStart, file: file, line: line)
        }
        XCTAssertEqual(lhs.lastFaceExecutionTime, rhs.lastFaceExecutionTime, accuracy: timeAccuracy, file: file, line: line)
        if let ld = lhs.lastFaceDetectedTime, let rd = rhs.lastFaceDetectedTime {
            XCTAssertEqual(ld, rd, accuracy: timeAccuracy, file: file, line: line)
        } else {
            XCTAssertEqual(lhs.lastFaceDetectedTime, rhs.lastFaceDetectedTime, file: file, line: line)
        }
    }
}

/// `PoseDetector` 間引きテスト用のモック `ProlongedAbsenceTracker`。
/// 内部状態を手動で制御し、実時間に依存しないテストを可能にする。
final class MockProlongedAbsenceTracker: @unchecked Sendable {
    var isProlongedAbsence: Bool = false
    var shouldExecuteFaceFallbackResult: Bool = true
    var faceDetectedHoldActiveResult: Bool = false
    var lastRecordedFaceExecutionTime: TimeInterval?
    var lastRecordedFaceDetectedTime: TimeInterval?
    var resetCallCount = 0

    let absentThreshold: TimeInterval = DimPowerPolicy.defaultAbsentThreshold
    let faceFallbackThrottleInterval: TimeInterval = 5.0

    func tick(isPersonDetected: Bool, now: TimeInterval) -> Bool {
        if isPersonDetected {
            isProlongedAbsence = false
        }
        return isProlongedAbsence
    }

    func shouldExecuteAndRecordFaceFallback(now: TimeInterval) -> Bool {
        if !isProlongedAbsence { return true }
        lastRecordedFaceExecutionTime = now
        lastRecordedFaceDetectedTime = now
        return shouldExecuteFaceFallbackResult
    }

    func recordFaceDetected(now: TimeInterval) {
        lastRecordedFaceDetectedTime = now
    }

    var faceDetectedHoldActive: Bool {
        faceDetectedHoldActiveResult
    }

    func reset() {
        isProlongedAbsence = false
        lastRecordedFaceExecutionTime = nil
        lastRecordedFaceDetectedTime = nil
        resetCallCount += 1
    }

    func snapshot() -> ProlongedAbsenceTracker.Snapshot {
        ProlongedAbsenceTracker.Snapshot(
            isProlongedAbsence: isProlongedAbsence,
            absenceStart: nil,
            lastFaceExecutionTime: lastRecordedFaceExecutionTime ?? -.infinity,
            lastFaceDetectedTime: lastRecordedFaceDetectedTime
        )
    }
}

/// 合成フレーム生成ユーティリティ。
/// `PoseDetector` テストで使用する CMSampleBuffer や PoseFrame を生成する。
enum SyntheticFrameGenerator {
    /// 姿勢キーポイントを含む `PoseFrame` を生成する。
    static func makePoseFrame(
        timestamp: TimeInterval = CACurrentMediaTime(),
        leftEar: Keypoint? = Keypoint(x: 0.3, y: 0.4, confidence: 0.9),
        rightEar: Keypoint? = Keypoint(x: 0.7, y: 0.4, confidence: 0.9),
        leftShoulder: Keypoint? = Keypoint(x: 0.4, y: 0.7, confidence: 0.9),
        rightShoulder: Keypoint? = Keypoint(x: 0.6, y: 0.7, confidence: 0.9)
    ) -> PoseFrame {
        PoseFrame(
            timestamp: timestamp,
            leftEar: leftEar,
            rightEar: rightEar,
            leftShoulder: leftShoulder,
            rightShoulder: rightShoulder
        )
    }

    /// 顔のみの `PoseFrame`（全キーポイント nil）を生成する。
    static func makePersonOnlyFrame(timestamp: TimeInterval = CACurrentMediaTime()) -> PoseFrame {
        PoseFrame(
            timestamp: timestamp,
            leftEar: nil,
            rightEar: nil,
            leftShoulder: nil,
            rightShoulder: nil
        )
    }

    /// キーポイントが全て nil の空 `PoseFrame` を生成する（姿勢観測ゼロ件相当）。
    static func makeEmptyPoseFrame(timestamp: TimeInterval = CACurrentMediaTime()) -> PoseFrame {
        PoseFrame(
            timestamp: timestamp,
            leftEar: nil,
            rightEar: nil,
            leftShoulder: nil,
            rightShoulder: nil
        )
    }

    /// 無効な `CMSampleBuffer` を生成する（画像データなし）。
    static func makeInvalidSampleBuffer() throws -> CMSampleBuffer {
        var sb: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,
            sampleCount: 0,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sb
        )
        guard status == noErr, let buffer = sb else {
            throw NSError(domain: "SyntheticFrameGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create invalid CMSampleBuffer"])
        }
        return buffer
    }
}

/// 単体テスト共通のテンプレート・アサーションユーティリティ。
enum TestTemplate {
    /// 非同期待機のヘルパー。
    static func waitForCondition(
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.01,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return condition()
    }

    /// 近似等価判定（TimeInterval 用）。
    static func assertTimeEqual(_ lhs: TimeInterval, _ rhs: TimeInterval, accuracy: TimeInterval = 1e-9, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs, rhs, accuracy: accuracy, message(), file: file, line: line)
    }
}