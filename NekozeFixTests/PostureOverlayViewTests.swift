import XCTest
import SwiftUI
@testable import NekozeFix

/// `PostureOverlayView` の閾値ガイド幾何計算検証。
/// 設計参照: design.md "PostureOverlayView" - 閾値ガイド（操作中のみ）の仕様。
final class PostureOverlayViewTests: XCTestCase {

    // MARK: - 角度ガイド弧の幾何計算

    func testAngleGuideArc_CalculatesCorrectStartEndAngles() {
        // Given: 基準角度 0度（真上）、閾値 5度
        let greenAngle: CGFloat = 0 // 真上（-π/2）

        // When: 製品ロジックで上限・下限角を計算
        let (upperAngle, lowerAngle) = PostureOverlayView.angleGuideAngles(
            centerAngle: greenAngle, thresholdDegrees: 5.0
        )

        // Then: 期待値と一致
        XCTAssertEqual(upperAngle, 5.0 * .pi / 180.0, accuracy: 1e-10)
        XCTAssertEqual(lowerAngle, -5.0 * .pi / 180.0, accuracy: 1e-10)
    }

    func testAngleGuideArc_WithNonZeroBaseAngle() {
        // Given: 基準角度 30度（右上）、閾値 8度
        let greenAngle: CGFloat = 30.0 * .pi / 180.0

        // When: 製品ロジックで上限・下限角を計算
        let (upperAngle, lowerAngle) = PostureOverlayView.angleGuideAngles(
            centerAngle: greenAngle, thresholdDegrees: 8.0
        )

        // Then: 基準角度を中心に ±閾値
        XCTAssertEqual(upperAngle, 38.0 * .pi / 180.0, accuracy: 1e-10)
        XCTAssertEqual(lowerAngle, 22.0 * .pi / 180.0, accuracy: 1e-10)
    }

    func testAngleGuideArc_WrapsAtPiBoundary() {
        // Given: 基準角度 175度（ほぼ真左）、閾値 10度 → 上限は -175度相当
        let greenAngle: CGFloat = 175.0 * .pi / 180.0

        // When: 製品ロジックで上限・下限角を計算（角度正規化は描画側で処理）
        let (upperAngle, lowerAngle) = PostureOverlayView.angleGuideAngles(
            centerAngle: greenAngle, thresholdDegrees: 10.0
        )

        // Then: 185度（= -175度）と 165度
        XCTAssertEqual(upperAngle, 185.0 * .pi / 180.0, accuracy: 1e-10)
        XCTAssertEqual(lowerAngle, 165.0 * .pi / 180.0, accuracy: 1e-10)
    }

    // MARK: - 距離ガイド線の幾何計算

    func testDistanceGuideLines_CalculatesPerpendicularVector() {
        // Given: 耳→肩ベクトル (1, 0) = 右向き、基準距離と画面条件
        let earShoulderVector = CGVector(dx: 1.0, dy: 0.0)
        let size = CGSize(width: 393, height: 852)
        let (sx, sy) = PostureOverlayView.aspectFitScales(imageAR: 4.0/3.0, viewAR: size.width/size.height)

        // When: 製品ロジックで画面換算と距離ガイドを計算
        let baseline = PostureOverlayView.baselineDistancePixels(
            referenceDistance: 0.15, earShoulderVector: earShoulderVector, sx: sx, sy: sy, size: size
        )
        let expected = 0.15 * hypot(earShoulderVector.dx * sx * size.width, earShoulderVector.dy * sy * size.height)

        // Then: 垂直方向の換算が正しく、baseline が期待値と一致する
        XCTAssertGreaterThan(baseline, 0)
        XCTAssertEqual(baseline, expected, accuracy: 1e-10)

        // 垂直ベクトルは幾何学的に (0,1) になること（製品外の純粋幾何確認）
        let perpX = -earShoulderVector.dy
        let perpY = earShoulderVector.dx
        XCTAssertEqual(perpX, 0.0, accuracy: 1e-10)
        XCTAssertEqual(perpY, 1.0, accuracy: 1e-10)
    }

    func testDistanceGuideLines_PerpendicularVector_ForDiagonalVector() {
        // Given: 耳→肩ベクトル (1, 1) = 右下45度（正規化済み想定）
        let earShoulderVector = CGVector(dx: 1.0, dy: 1.0)
        let len = hypot(earShoulderVector.dx, earShoulderVector.dy)
        let unitX = earShoulderVector.dx / len
        let unitY = earShoulderVector.dy / len
        let unit = CGVector(dx: unitX, dy: unitY)
        let size = CGSize(width: 393, height: 852)
        let (sx, sy) = PostureOverlayView.aspectFitScales(imageAR: 4.0/3.0, viewAR: size.width/size.height)

        // When: 製品ロジックで画面換算（x/y 別スケールを向き依存で適用）
        let perUnit = PostureOverlayView.baselineDistancePixels(
            referenceDistance: 1.0, earShoulderVector: unit, sx: sx, sy: sy, size: size
        )
        let expected = hypot(unitX * sx * size.width, unitY * sy * size.height)

        // Then: 向き依存の換算と一致し、垂直性も保つ
        XCTAssertEqual(perUnit, expected, accuracy: 1e-10)
        let perpX = -unitY
        let perpY = unitX
        XCTAssertEqual(unitX * perpX + unitY * perpY, 0.0, accuracy: 1e-10)
    }

    func testDistanceGuideLines_LineEndpoints() {
        // Given: 中心点 (100, 40)、垂直ベクトル (1, 0) = 右向き、線分半長 40
        let center = CGPoint(x: 100, y: 40)
        let perpX: CGFloat = 1.0
        let perpY: CGFloat = 0.0
        let halfLength: CGFloat = 40

        // When: 線分の端点を計算
        let start = CGPoint(x: center.x - perpX * halfLength, y: center.y - perpY * halfLength)
        let end = CGPoint(x: center.x + perpX * halfLength, y: center.y + perpY * halfLength)

        // Then: 水平線分 (60, 40) 〜 (140, 40)
        XCTAssertEqual(start.x, 60.0, accuracy: 1e-10)
        XCTAssertEqual(start.y, 40.0, accuracy: 1e-10)
        XCTAssertEqual(end.x, 140.0, accuracy: 1e-10)
        XCTAssertEqual(end.y, 40.0, accuracy: 1e-10)
    }

    // MARK: - AspectFit 補正係数の一致検証

    func testAspectFitScales_MatchesPointNormalization() {
        // Given: 画像アスペクト比 4:3、画面サイズ様々
        let imageAspectRatio: CGFloat = 4.0 / 3.0

        // When/Then: 製品ロジックの補正係数を検証
        // 横長画面 (ピラーボックス)
        let (sx1, sy1) = PostureOverlayView.aspectFitScales(imageAR: imageAspectRatio, viewAR: 16.0 / 9.0)
        XCTAssertEqual(sx1, (4.0/3.0) / (16.0/9.0), accuracy: 1e-10)
        XCTAssertEqual(sy1, 1.0, accuracy: 1e-10)

        // 縦長画面 (レターボックス)
        let (sx2, sy2) = PostureOverlayView.aspectFitScales(imageAR: imageAspectRatio, viewAR: 3.0 / 4.0)
        XCTAssertEqual(sx2, 1.0, accuracy: 1e-10)
        XCTAssertEqual(sy2, (3.0/4.0) / (4.0/3.0), accuracy: 1e-10)

        // 正方形
        let (sx3, sy3) = PostureOverlayView.aspectFitScales(imageAR: imageAspectRatio, viewAR: 1.0)
        XCTAssertEqual(sx3, 1.0, accuracy: 1e-10)
        XCTAssertEqual(sy3, 1.0 / (4.0/3.0), accuracy: 1e-10)
    }

    // MARK: - 距離閾値ドット（上限のみ・中心線延長上）

    func testUpperDistance_MatchesVerdictBoundary() {
        // Given: 基準距離 50、閾値 20%（判定式 baseline × (1 + threshold/100) と同一）
        // Then: 上限のみが判定境界と一致する
        XCTAssertEqual(PostureOverlayView.upperDistance(baselineDistance: 50, thresholdPercent: 20.0), 60.0, accuracy: 1e-10)
        XCTAssertEqual(PostureOverlayView.upperDistance(baselineDistance: 50, thresholdPercent: 0.0), 50.0, accuracy: 1e-10)
        XCTAssertEqual(PostureOverlayView.upperDistance(baselineDistance: 50, thresholdPercent: 8.0), 54.0, accuracy: 1e-10)
    }

    func testDistanceThresholdDots_OnBothAngleRaysAtUpperDistance() {
        // Given: 肩点 (100,100)、中心線は真上（-π/2）、角度閾値 10°、基準距離 50、距離閾値 20%
        // 耳は肩から中心線方向に基準距離の位置 (100,50) にある想定
        let startPoint = CGPoint(x: 100, y: 100)
        let centerAngle: CGFloat = -.pi / 2
        let (upperAngle, lowerAngle) = PostureOverlayView.angleGuideAngles(
            centerAngle: centerAngle, thresholdDegrees: 10.0
        )
        let baseline: CGFloat = 50
        let upper = PostureOverlayView.upperDistance(baselineDistance: baseline, thresholdPercent: 20.0)

        // When: 製品ロジックで2ドット位置を計算
        let (upperDot, lowerDot) = PostureOverlayView.distanceThresholdDots(
            startPoint: startPoint, upperAngle: upperAngle, lowerAngle: lowerAngle, upperDistance: upper
        )

        // Then: 両ドットとも上下の角度閾値レイ上の上限距離にある（弧の両端）
        XCTAssertEqual(atan2(upperDot.y - startPoint.y, upperDot.x - startPoint.x), upperAngle, accuracy: 1e-10)
        XCTAssertEqual(atan2(lowerDot.y - startPoint.y, lowerDot.x - startPoint.x), lowerAngle, accuracy: 1e-10)
        XCTAssertEqual(hypot(upperDot.x - startPoint.x, upperDot.y - startPoint.y), upper, accuracy: 1e-10)
        XCTAssertEqual(hypot(lowerDot.x - startPoint.x, lowerDot.y - startPoint.y), upper, accuracy: 1e-10)
        XCTAssertNotEqual(upperDot.x, lowerDot.x, "2ドットは異なる位置にある")

        // Then: 両ドットとも耳より上部（肩からの距離が基準距離を超える）
        let earPoint = CGPoint(x: startPoint.x + cos(centerAngle) * baseline,
                               y: startPoint.y + sin(centerAngle) * baseline)
        XCTAssertGreaterThan(earPoint.y, upperDot.y, "画面座標でドットは耳より上（y が小さい）")
        XCTAssertGreaterThan(earPoint.y, lowerDot.y, "画面座標でドットは耳より上（y が小さい）")
    }

    func testDistanceThresholdPoint_DiagonalCenterRay() {
        // Given: 斜め方向の中心線でも中心角レイ上に載ること
        let startPoint = CGPoint(x: 100, y: 100)
        let centerAngle: CGFloat = 0 // 右向き
        let upper: CGFloat = 60

        // When: 製品ロジックでドット位置を計算
        let dot = PostureOverlayView.distanceThresholdPoint(
            startPoint: startPoint, centerAngle: centerAngle, upperDistance: upper
        )

        // Then: (160, 100) で角度オフセット線（±閾値）上ではない
        XCTAssertEqual(dot.x, 160.0, accuracy: 1e-10)
        XCTAssertEqual(dot.y, 100.0, accuracy: 1e-10)
    }

    // MARK: - ヘルパー（製品ロジックへの委譲確認用。重複実装はしない）
}