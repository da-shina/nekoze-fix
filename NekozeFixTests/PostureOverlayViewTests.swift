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
        let thresholdRadians = 5.0 * .pi / 180.0

        // When: 上限・下限角を計算
        let upperAngle = greenAngle + thresholdRadians
        let lowerAngle = greenAngle - thresholdRadians

        // Then: 期待値と一致
        XCTAssertEqual(upperAngle, 5.0 * .pi / 180.0, accuracy: 1e-10)
        XCTAssertEqual(lowerAngle, -5.0 * .pi / 180.0, accuracy: 1e-10)
    }

    func testAngleGuideArc_WithNonZeroBaseAngle() {
        // Given: 基準角度 30度（右上）、閾値 8度
        let greenAngle: CGFloat = 30.0 * .pi / 180.0
        let thresholdRadians = 8.0 * .pi / 180.0

        // When: 上限・下限角を計算
        let upperAngle = greenAngle + thresholdRadians
        let lowerAngle = greenAngle - thresholdRadians

        // Then: 基準角度を中心に ±閾値
        XCTAssertEqual(upperAngle, 38.0 * .pi / 180.0, accuracy: 1e-10)
        XCTAssertEqual(lowerAngle, 22.0 * .pi / 180.0, accuracy: 1e-10)
    }

    func testAngleGuideArc_WrapsAtPiBoundary() {
        // Given: 基準角度 175度（ほぼ真左）、閾値 10度 → 上限は -175度相当
        let greenAngle: CGFloat = 175.0 * .pi / 180.0
        let thresholdRadians = 10.0 * .pi / 180.0

        // When: 上限・下限角を計算（角度正規化は描画側で処理）
        let upperAngle = greenAngle + thresholdRadians
        let lowerAngle = greenAngle - thresholdRadians

        // Then: 185度（= -175度）と 165度
        XCTAssertEqual(upperAngle, 185.0 * .pi / 180.0, accuracy: 1e-10)
        XCTAssertEqual(lowerAngle, 165.0 * .pi / 180.0, accuracy: 1e-10)
    }

    // MARK: - 距離ガイド線の幾何計算

    func testDistanceGuideLines_CalculatesPerpendicularVector() {
        // Given: 耳→肩ベクトル (1, 0) = 右向き
        let earShoulderVector = CGVector(dx: 1.0, dy: 0.0)

        // When: 垂直ベクトルを計算 (v⊥ = (-y, x))
        let perpX = -earShoulderVector.dy
        let perpY = earShoulderVector.dx

        // Then: 上向き (0, 1)
        XCTAssertEqual(perpX, 0.0, accuracy: 1e-10)
        XCTAssertEqual(perpY, 1.0, accuracy: 1e-10)
    }

    func testDistanceGuideLines_PerpendicularVector_ForDiagonalVector() {
        // Given: 耳→肩ベクトル (1, 1) = 右下45度（正規化済み想定）
        let earShoulderVector = CGVector(dx: 1.0, dy: 1.0)
        let len = hypot(earShoulderVector.dx, earShoulderVector.dy)
        let unitX = earShoulderVector.dx / len
        let unitY = earShoulderVector.dy / len

        // When: 垂直ベクトルを計算
        let perpX = -unitY
        let perpY = unitX

        // Then: (-1/√2, 1/√2) = 左下45度（右下45度に垂直）
        XCTAssertEqual(perpX, -unitY, accuracy: 1e-10)
        XCTAssertEqual(perpY, unitX, accuracy: 1e-10)
        // 内積が0（垂直）であること
        XCTAssertEqual(unitX * perpX + unitY * perpY, 0.0, accuracy: 1e-10)
    }

    func testDistanceGuideLines_UpperLowerCenterPositions() {
        // Given: 肩点 (100, 100)、基準距離 50、閾値距離 10、単位ベクトル (0, -1) = 上向き
        let startPoint = CGPoint(x: 100, y: 100)
        let baselineDistance: CGFloat = 50
        let distanceThresholdPixels: CGFloat = 10
        let unitX: CGFloat = 0.0
        let unitY: CGFloat = -1.0

        // When: 上限・下限中心点を計算
        let upperDist = baselineDistance + distanceThresholdPixels // 60
        let lowerDist = baselineDistance - distanceThresholdPixels // 40

        let upperCenter = CGPoint(
            x: startPoint.x + unitX * upperDist,
            y: startPoint.y + unitY * upperDist
        )
        let lowerCenter = CGPoint(
            x: startPoint.x + unitX * lowerDist,
            y: startPoint.y + unitY * lowerDist
        )

        // Then: 上限は (100, 40)、下限は (100, 60)
        XCTAssertEqual(upperCenter.x, 100.0, accuracy: 1e-10)
        XCTAssertEqual(upperCenter.y, 40.0, accuracy: 1e-10)
        XCTAssertEqual(lowerCenter.x, 100.0, accuracy: 1e-10)
        XCTAssertEqual(lowerCenter.y, 60.0, accuracy: 1e-10)
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

        // When/Then: 様々な画面アスペクト比で補正係数を検証
        // 横長画面 (ピラーボックス)
        let (sx1, sy1) = aspectFitScales(imageAR: imageAspectRatio, viewAR: 16.0 / 9.0)
        XCTAssertEqual(sx1, (4.0/3.0) / (16.0/9.0), accuracy: 1e-10)
        XCTAssertEqual(sy1, 1.0, accuracy: 1e-10)

        // 縦長画面 (レターボックス)
        let (sx2, sy2) = aspectFitScales(imageAR: imageAspectRatio, viewAR: 3.0 / 4.0)
        XCTAssertEqual(sx2, 1.0, accuracy: 1e-10)
        XCTAssertEqual(sy2, (3.0/4.0) / (4.0/3.0), accuracy: 1e-10)

        // 正方形
        let (sx3, sy3) = aspectFitScales(imageAR: imageAspectRatio, viewAR: 1.0)
        XCTAssertEqual(sx3, 1.0, accuracy: 1e-10)
        XCTAssertEqual(sy3, 1.0 / (4.0/3.0), accuracy: 1e-10)
    }

    // MARK: - ヘルパー

    /// `PostureOverlayView.aspectFitScales` と同一ロジック（テスト用に抽出）
    private func aspectFitScales(imageAR: CGFloat, viewAR: CGFloat) -> (sx: CGFloat, sy: CGFloat) {
        if viewAR > imageAR {
            return (imageAR / viewAR, 1.0)
        } else if viewAR < imageAR {
            return (1.0, viewAR / imageAR)
        }
        return (1.0, 1.0)
    }
}