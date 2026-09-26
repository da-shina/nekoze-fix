import XCTest
@testable import NekozeFix

final class PostureAnalyzerTests: XCTestCase {

    private var postureAnalyzer: PostureAnalyzer!

    override func setUp() {
        super.setUp()
        postureAnalyzer = PostureAnalyzer()
    }

    override func tearDown() {
        postureAnalyzer = nil
        super.tearDown()
    }

    func testNearSideSelection_LeftShoulderSmallerX() {
        // 前提: 左肩のx座標 < 右肩のx座標
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 155, y: 350, confidence: 0.9),  // 肩から少し右にずらして小さな角度を作る
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.9),
            leftShoulder: Keypoint(x: 150, y: 250, confidence: 0.9),
            rightShoulder: Keypoint(x: 250, y: 250, confidence: 0.9)
        )

        // 手順
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.farSideDetected, true)
        XCTAssertEqual(verdict, .good) // 角度は小さい（約2.86度）のため良好判定
    }

    func testNearSideSelection_RightShoulderSmallerX() {
        // 前提: 右肩のx座標 < 左肩のx座標
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 250, y: 200, confidence: 0.9),
            rightEar: Keypoint(x: 100, y: 200, confidence: 0.9),
            leftShoulder: Keypoint(x: 250, y: 250, confidence: 0.9),
            rightShoulder: Keypoint(x: 150, y: 250, confidence: 0.9)
        )

        // 手順
        let (sample, _) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertEqual(sample?.nearSide, .right)
        XCTAssertEqual(sample?.farSideDetected, true)
    }

    func testAngleCalculation_Acute0to90Degrees() {
        // 前提: 角度が既知のフレームを作成
        // shoulder at (100, 200), ear at (100, 100) -> 真上、0度
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 100, y: 100, confidence: 0.9),
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.0), // 無効
            leftShoulder: Keypoint(x: 100, y: 200, confidence: 0.9),
            rightShoulder: Keypoint(x: 300, y: 200, confidence: 0.0)  // 無効
        )

        // 手順
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.nearAngleDegrees ?? 0, 0.0, accuracy: 0.1)
        XCTAssertEqual(verdict, .good)
    }

    func testSlouchDetection_WhenAngleExceedsThreshold() {
        // 前提: リファレンス角度0度、現在の角度15度、しきい値10度
        // 耳が肩より右にあるフレームを作成して角度を作る
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 115, y: 190, confidence: 0.9), // 角度を作る
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.0), // 無効
            leftShoulder: Keypoint(x: 100, y: 200, confidence: 0.9),
            rightShoulder: Keypoint(x: 300, y: 200, confidence: 0.0)  // 無効
        )

        // 手順
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertGreaterThan(sample!.nearAngleDegrees, 10.0)
        XCTAssertEqual(verdict, .slouchCandidate)
    }

    func testInsufficientKeypoints_ReturnsNilSample() {
        // 前提: 有効なキーがない
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 100, y: 200, confidence: 0.2), // しきい値(0.3)以下
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.2),
            leftShoulder: Keypoint(x: 150, y: 250, confidence: 0.2),
            rightShoulder: Keypoint(x: 250, y: 250, confidence: 0.2)
        )

        // 手順
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertNil(sample)
        XCTAssertEqual(verdict, .insufficientKeypoints)
    }

    func testOneSideDetection_TreatsDetectedSideAsNear() {
        // 前提: 左側のみ有効
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 100, y: 200, confidence: 0.9),
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.0), // 無効
            leftShoulder: Keypoint(x: 150, y: 250, confidence: 0.9),
            rightShoulder: Keypoint(x: 250, y: 250, confidence: 0.0)  // 無効
        )

        // 手順
        let (sample, _) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.farSideDetected, false) // far側未検出
    }

    func testHysteresis_SwitchesToOtherSideWhenClearlyReversed() {
        // 前提: 前回 .left、今回は右肩が明確に近い (rx - lx = -100 >> 閾値0.02)
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 300, y: 200, confidence: 0.9),
            rightEar: Keypoint(x: 155, y: 350, confidence: 0.9),
            leftShoulder: Keypoint(x: 300, y: 250, confidence: 0.9),
            rightShoulder: Keypoint(x: 200, y: 250, confidence: 0.9)
        )

        // 手順
        let (sample, _) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            previousNearSide: .left
        )

        // 検証: 差が閾値超なら逆側へ切り替わるべき（バグ時は .left に固定されていた）
        XCTAssertEqual(sample?.nearSide, .right)
    }

    func testHysteresis_KeepsPreviousSideWithinThreshold() {
        // 前提: 前回 .left、差が閾値内 (rx - lx = 0.01) で右肩がわずかに近い
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.51, y: 0.8, confidence: 0.9),
            rightEar: Keypoint(x: 0.5, y: 0.8, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.51, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.5, y: 0.6, confidence: 0.9)
        )

        // 手順
        let (sample, _) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            previousNearSide: .left
        )

        // 検証: 小差では前回の判定を維持
        XCTAssertEqual(sample?.nearSide, .left)
    }

    // MARK: - 前出し距離指標: OR 判定（FQ1/FQ6）

    /// 角度 GOOD・距離 OVER → slouchCandidate。距離はロック側（右）ペアで評価され、
    /// sample.nearDistance にはロック側の値が入る（design「nearDistance は監視中はロック側」）。
    func testDistanceOver_AngleUnder_SlouchCandidate() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),    // 近側（左）: 角度0度・距離0.1
            rightEar: Keypoint(x: 0.7, y: 0.4, confidence: 0.9),   // ロック側（右）: 距離0.2
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
        let metric = DistanceMetric(side: .right, referenceDistance: 0.18) // 閾値 0.18*1.08=0.1944 < 0.2

        let (sample, verdict) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 8.0
        )

        XCTAssertEqual(sample?.nearSide, .left)                        // 角度は近側（左）で評価継続
        XCTAssertEqual(sample?.nearDistance ?? 0, 0.2, accuracy: 0.001) // 距離はロック側（右）の値
        XCTAssertEqual(verdict, .slouchCandidate)
    }

    /// 角度 OVER・距離 GOOD → slouchCandidate（OR の反対辺）
    func testAngleOver_DistanceUnder_SlouchCandidate() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.35, y: 0.5, confidence: 0.9),   // 角度約26.6度 > 10
            rightEar: Keypoint(x: 0.7, y: 0.42, confidence: 0.9),  // 距離0.18 < 0.1944
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
        let metric = DistanceMetric(side: .right, referenceDistance: 0.18)

        let (_, verdict) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 8.0
        )

        XCTAssertEqual(verdict, .slouchCandidate)
    }

    /// 両方 UNDER → good
    func testAngleAndDistanceBothUnder_Good() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),    // 角度0度
            rightEar: Keypoint(x: 0.7, y: 0.41, confidence: 0.9),  // 距離0.19 < 0.1944
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
        let metric = DistanceMetric(side: .right, referenceDistance: 0.18)

        let (_, verdict) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 8.0
        )

        XCTAssertEqual(verdict, .good)
    }

    /// ロック側ペア欠測（信頼度 < 0.3）→ 距離スキップ、角度のみで判定（FQ1）
    func testLockSideMissing_DistanceSkipped_AngleOnlyVerdict() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),        // 角度0度 → good
            rightEar: Keypoint(x: 0.7, y: 0.3, confidence: 0.1),        // ロック側無効（距離0.3 なら OVER 相当）
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
        let metric = DistanceMetric(side: .right, referenceDistance: 0.18)

        let (sample, verdict) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 8.0
        )

        // ロック側が読めなくても角度サンプルは出る。nearDistance はロック側が取れないため近側の素値
        XCTAssertEqual(sample?.nearDistance ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(verdict, .good) // 角度0度、距離スキップ
    }

    /// 基準比ちょうど閾値 → candidate（以上で発火）
    func testDistanceExactlyAtThreshold_SlouchCandidate() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),     // 角度0度
            rightEar: Keypoint(x: 0.7, y: 0.35, confidence: 0.9),   // 距離0.25
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
        // 2進数で厳密に一致する値: 0.2 * 1.25 = 0.25（pct 25 は境界検証用の仮値、UI 範囲外）
        let metric = DistanceMetric(side: .right, referenceDistance: 0.2)

        let (_, verdict) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 25.0
        )

        XCTAssertEqual(verdict, .slouchCandidate)
    }

    /// distanceMetric nil（校正中・第1段相当）→ 近側距離がそのまま記録され角度のみ判定
    func testNilDistanceMetric_KeepsNearSideDistanceAndAngleOnly() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.2, confidence: 0.9),  // 右は極端に遠いが無視される
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )

        let (sample, verdict) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )

        XCTAssertEqual(sample?.nearDistance ?? 0, 0.1, accuracy: 0.001) // 近側（左）距離
        XCTAssertEqual(verdict, .good)
    }

    // MARK: - 両側距離基準（フォールバック）

    /// ロック側欠測時: 反対側の fallbackReferenceDistance で距離評価を継続
    func testDistanceFallback_WhenLockSideMissing_UsesOtherSide() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: nil,  // ロック側（左）欠測
            rightEar: Keypoint(x: 0.7, y: 0.35, confidence: 0.9),
            leftShoulder: nil,
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
        // metric.side = .left だが左キーポイント nil → 右側でフォールバック
        let metric = DistanceMetric(side: .left, referenceDistance: 0.18, fallbackReferenceDistance: 0.22)
        let (_, verdict) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 8.0
        )
        // 右距離 0.25 >= 0.22 * 1.08 = 0.2376 → slouchCandidate
        XCTAssertEqual(verdict, .slouchCandidate)
    }

    /// ロック側欠測 + フォールバック基準なし → 距離評価スキップ（角度のみ）
    func testDistanceFallback_NoFallbackReference_SkipsDistance() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: nil,
            rightEar: Keypoint(x: 0.7, y: 0.35, confidence: 0.9),
            leftShoulder: nil,
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
        let metric = DistanceMetric(side: .left, referenceDistance: 0.18) // fallback nil
        let (_, verdict) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 8.0
        )
        // ロック側 nil + フォールバックなし → 距離スキップ。角度 0 < 10 → good
        XCTAssertEqual(verdict, .good)
    }

    /// 両側検出時に遠側の角度・距離も返す
    func testBothSidesDetected_ReturnsFarSideData() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.45, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
        let (sample, _) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        XCTAssertNotNil(sample?.farAngleDegrees, "両側検出時は遠側角度が非nil")
        XCTAssertNotNil(sample?.farDistance, "両側検出時は遠側距離が非nil")
    }

    // MARK: - 両肩直交基準とフォールバック

    /// 両肩が傾いている場合でも、耳〜肩が肩ラインに直角であれば角度0度（良好）と判定される
    /// アスペクト比補正（x 成分に AR を適用）後も同じ結果になることを確認
    func testAngleCalculation_TiltedShoulders_CalculatesAngleRelativeToShoulderPerpendicular() {
        // 4:3 アスペクト比（AR = 4/3）で検証
        let ar: Double = 4.0 / 3.0
        // 左肩 (0.2, 0.5), 右肩 (0.6, 0.6)
        // 補正後肩ベクトル: (0.4*AR, 0.1) = (0.5333, 0.1)
        let sdx = 0.4 * ar
        let sdy = 0.1
        let sLen = sqrt(sdx * sdx + sdy * sdy)
        // 補正後垂線単位ベクトル
        let ux = -sdy / sLen
        let uy = sdx / sLen
        // 耳を垂線方向に配置: 補正後ベクトルが垂線と平行 → 角度0°
        let earDx = 0.2 * ux / ar
        let earDy = 0.2 * uy
        let earX = 0.2 + earDx
        let earY = 0.5 + earDy

        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: earX, y: earY, confidence: 0.9),
            rightEar: Keypoint(x: 0.8, y: 0.8, confidence: 0.0), // 無効
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.6, y: 0.6, confidence: 0.9)
        )

        let (sample, verdict) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            videoAspectRatio: ar
        )

        // 両肩垂線との角度は 0 度（補正済み座標系で計算）
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.nearAngleDegrees ?? 0, 0.0, accuracy: 0.1)
        XCTAssertEqual(verdict, .good)
    }

    /// 片肩しか検出できない場合は従来の画像垂直 (0, 1) へ安全にフォールバックする
    func testAngleCalculation_OneShoulderOnly_FallsBackToImageVertical() {
        // 左肩 (0.2, 0.5)、右肩なし。左耳 (0.2, 0.7) は画像垂直真上
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.7, confidence: 0.9),
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: nil
        )

        let (sample, verdict) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )

        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.nearAngleDegrees ?? 0, 0.0, accuracy: 0.1)
        XCTAssertEqual(verdict, .good)
    }

    // MARK: - アスペクト比補正

    /// アスペクト比補正（x 成分に AR を適用）により、肩が傾斜した場合に正規化座標と等方座標の角度差が是正される
    func testAspectRatioCorrection_TiltedShoulders_CorrectsAngleDistortion() {
        // 4:3 フレーム。左肩 (0.2, 0.5)、右肩 (0.6, 0.6)
        // 肩ベクトル（正規化）: (0.4, 0.1) → atan2(0.1, 0.4) ≈ 14.0°
        // 肩ベクトル（等方・x*AR）: (0.5333, 0.1) → atan2(0.1, 0.5333) ≈ 10.6°
        // 真の角度差は ~3.4°
        //
        // 耳を肩ラインに直角（等方座標）に配置 → 補正後は角度0°
        // 補正なしの場合は ~3.4° の誤差が生じるはず
        let ar: Double = 4.0 / 3.0
        let sdx = 0.4 * ar
        let sdy = 0.1
        let sLen = sqrt(sdx * sdx + sdy * sdy)
        let ux = -sdy / sLen
        let uy = sdx / sLen
        let earDx = 0.2 * ux / ar
        let earDy = 0.2 * uy
        let earX = 0.2 + earDx
        let earY = 0.5 + earDy

        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: earX, y: earY, confidence: 0.9),
            rightEar: Keypoint(x: 0.8, y: 0.8, confidence: 0.0),
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.6, y: 0.6, confidence: 0.9)
        )

        // 補正あり（4:3）: 角度0°
        let (sampleCorrected, _) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            videoAspectRatio: ar
        )
        XCTAssertEqual(sampleCorrected?.nearAngleDegrees ?? 0, 0.0, accuracy: 0.1,
                       "補正後は肩ライン直角の耳-肩ベクトルが角度0°になるべき")

        // 補正なし（1:1 = 正方形）: 角度にズレが生じる
        let (sampleUncorrected, _) = postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            videoAspectRatio: 1.0
        )
        XCTAssertGreaterThan(sampleUncorrected?.nearAngleDegrees ?? 0, 1.0,
                             "補正なし（1:1）では肩傾斜時に角度誤差が生じるべき")
    }
}
