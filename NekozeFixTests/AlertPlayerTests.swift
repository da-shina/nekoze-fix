import XCTest
@testable import NekozeFix

final class AlertPlayerTests: XCTestCase {
    var sut: AlertPlayer!
    let invalidURL = URL(fileURLWithPath: "/dev/null") // 有効な音声ファイルではない

    override func setUp() {
        super.setUp()
        sut = AlertPlayer(soundURL: invalidURL)
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func testInitWithInvalidURL_configureSessionThrows() {
        // 前提: 無効なURLで初期化されたAlertPlayer
        // 手順: configureSessionが呼ばれる
        // 検証: エラーが発生するはず
        XCTAssertThrowsError(try sut.configureSession()) { error in
            XCTAssertTrue(error is NSError)
        }
    }

    func testPlayOnceWithNilPlayer_doesNotCrash() {
        // 前提: audioPlayerがnilのAlertPlayer（無効なURLのため）
        // 手順: playOnceが呼ばれる
        // 検証: クラッシュしないはず
        XCTAssertNoThrow(sut.playOnce())
    }

    func testStartRepeatingWithNilPlayer_doesNotCrash() {
        // 前提: audioPlayerがnilのAlertPlayer
        // 手順: startRepeatingが呼ばれる
        // 検証: クラッシュしないはず
        XCTAssertNoThrow(sut.startRepeating())
    }

    func testStopWithNilPlayer_doesNotCrash() {
        // 前提: audioPlayerがnilのAlertPlayer
        // 手順: stopが呼ばれる
        // 検証: クラッシュしないはず
        XCTAssertNoThrow(sut.stop())
    }

    func testIsPlayingWithNilPlayer_returnsFalse() {
        // 前提: audioPlayerがnilのAlertPlayer
        // 検証: isPlayingはfalseであるはず
        XCTAssertFalse(sut.isPlaying)
    }
}