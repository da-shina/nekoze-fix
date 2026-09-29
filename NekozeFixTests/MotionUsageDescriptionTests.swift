import XCTest

/// Task 11.2: モーション利用目的文言（NSMotionUsageDescription）のビルド時検証。
/// カメラ文言（NSCameraUsageDescription）の方式に倣い、Info.plistキーとして日英二文で提供する。
/// 権限拒否時の代替継続は既存フォールバック（距離スキップ・角度のみ判定）で担保され、本タスクは文言追加のみを所有する。
final class MotionUsageDescriptionTests: XCTestCase {
    static let expectedMotionUsageDescription =
        "姿勢の角度を正しく測るために、端末の傾き（モーション）を利用します。NekozeFix uses motion data to measure device tilt for accurate posture angle detection."

    func testMotionUsageDescriptionIsPresentInBuiltBundle() {
        let value = Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") as? String
        XCTAssertEqual(
            value, Self.expectedMotionUsageDescription,
            "NSMotionUsageDescription が built app の Info.plist に日英二文で存在すること（project.pbxproj の INFOPLIST_KEY_NSMotionUsageDescription 由来）"
        )
    }

    func testMotionUsageDescriptionIsJapaneseAndEnglishTwoSentences() {
        let text = Self.expectedMotionUsageDescription
        XCTAssertTrue(text.contains("。"), "日本語の一文（句点あり）を含むこと")
        XCTAssertTrue(text.contains("."), "英語の一文（ピリオドあり）を含むこと")
        XCTAssertTrue(text.contains("傾き"), "利用目的（端末の傾き計測）への言及を含むこと")
        XCTAssertTrue(text.contains("motion"), "英語文に motion への言及を含むこと")
    }

    func testSourceInfoPlistContainsMotionWording() throws {
        let plistURL = try XCTUnwrap(
            Self.repoFileURL(["NekozeFix", "Info.plist"]),
            "ソース NekozeFix/Info.plist がリポジトリに存在すること"
        )
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "Info.plist が辞書形式として読めること"
        )
        XCTAssertEqual(
            plist["NSMotionUsageDescription"] as? String, Self.expectedMotionUsageDescription,
            "ソース Info.plist（カメラ文言と同方式）にも同一文言が存在すること"
        )
    }

    func testProjectDeclaresMotionKeyForGeneratedPlist() throws {
        let pbxprojURL = try XCTUnwrap(
            Self.repoFileURL(["NekozeFix.xcodeproj", "project.pbxproj"]),
            "project.pbxproj がリポジトリに存在すること"
        )
        let content = try String(contentsOf: pbxprojURL, encoding: .utf8)
        XCTAssertTrue(
            content.contains("INFOPLIST_KEY_NSMotionUsageDescription"),
            "GENERATE_INFOPLIST_FILE=YES のため built bundle 反映には pbxproj の INFOPLIST_KEY_NSMotionUsageDescription が必要"
        )
    }

    private static func repoFileURL(_ components: [String]) -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // MotionUsageDescriptionTests.swift
        url.deleteLastPathComponent() // NekozeFixTests/
        for component in components {
            url.appendPathComponent(component)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
