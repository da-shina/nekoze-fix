import XCTest
@testable import NekozeFix

/// MonitorView の状態→表示(アイコン・文言)対応表の特性テスト。
/// 製品: MonitorView.statusContent/postureContent。
/// 文言・アイコンの取り違えはユーザー可視の表示デグレであり、
/// 6連switchの一本化(タプル化)を行う際も本テストが振る舞いを固定する。
/// 色は対象外(自明な1行対応のため現状維持)。
final class MonitorViewStyleTests: XCTestCase {
    // MARK: - 状態表示

    func testStatusContent_monitoring() {
        let content = MonitorView.statusContent(for: .monitoring)
        XCTAssertEqual(content.icon, "antenna.radiowaves.left.and.right")
        XCTAssertEqual(content.text, "監視中")
    }

    func testStatusContent_idle() {
        let content = MonitorView.statusContent(for: .idle)
        XCTAssertEqual(content.icon, "stop.circle")
        XCTAssertEqual(content.text, "停止中")
    }

    func testStatusContent_nonMonitoringPhases_shareStoppedStyle() {
        for phase: SessionPhase in [.awaitingPermission, .permissionDenied, .calibrating, .idle] {
            let content = MonitorView.statusContent(for: phase)
            XCTAssertEqual(content.icon, "stop.circle", "\(phase) は停止表示")
            XCTAssertEqual(content.text, "停止中", "\(phase) は停止表示")
        }
    }

    // MARK: - 姿勢表示

    func testPostureContent_good() {
        let content = MonitorView.postureContent(for: .good)
        XCTAssertEqual(content.icon, "checkmark.circle.fill")
        XCTAssertEqual(content.text, "良好")
    }

    func testPostureContent_slouch() {
        let content = MonitorView.postureContent(for: .slouch)
        XCTAssertEqual(content.icon, "exclamationmark.triangle.fill")
        XCTAssertEqual(content.text, "猫背を検出")
    }

    func testPostureContent_personMissing() {
        let content = MonitorView.postureContent(for: .personMissing)
        XCTAssertEqual(content.icon, "person.slash.fill")
        XCTAssertEqual(content.text, "人を検出できません")
    }
}
