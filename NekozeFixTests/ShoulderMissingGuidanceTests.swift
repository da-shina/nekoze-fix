import XCTest
@testable import NekozeFix

/// なで肩ガイダンスの向き分岐（ADR 0014）。
/// ランドスケープ×なで肩は Body Pose 観測自体が空になるため検出救済不能と実測判定され、
/// 画角に収める実効手段の案内へ分岐する。その分岐条件と文言の固定テスト。
@MainActor
final class ShoulderMissingGuidanceTests: XCTestCase {

    func testPortraitGuidance_asksToFrameShoulders() {
        let text = shoulderMissingGuidance(isLandscape: false)
        XCTAssertTrue(text.contains("肩まで収めて"))
        XCTAssertFalse(text.contains("離す"), "ポートレートにランドスケープ用文言を出さない")
    }

    func testLandscapeGuidance_offersEffectiveMeans() {
        let text = shoulderMissingGuidance(isLandscape: true)
        XCTAssertTrue(text.contains("離す"), "ランドスケープは画角が狭い具体手段を案内する")
        XCTAssertTrue(text.contains("高さ"), "実機検収で有効確認済み: カメラの高さ・距離調整を案内")
    }

    /// Session Snapshot の isLandscape がデフォルト false（ポートレート）であることを確認
    func testSnapshot_defaultIsPortrait() {
        XCTAssertFalse(SessionSnapshot().isLandscape)
    }
}
