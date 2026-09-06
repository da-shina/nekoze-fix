import XCTest
@testable import NekozeFix

final class AlertPlayerTests: XCTestCase {
    var sut: AlertPlayer!
    let invalidURL = URL(fileURLWithPath: "/dev/null") // Not a valid audio file

    override func setUp() {
        super.setUp()
        sut = AlertPlayer(soundURL: invalidURL)
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func testInitWithInvalidURL_configureSessionThrows() {
        // Given: AlertPlayer initialized with invalid URL
        // When: configureSession is called
        // Then: it should throw an error
        XCTAssertThrowsError(try sut.configureSession()) { error in
            XCTAssertTrue(error is NSError)
        }
    }

    func testPlayOnceWithNilPlayer_doesNotCrash() {
        // Given: AlertPlayer with nil audioPlayer (due to invalid URL)
        // When: playOnce is called
        // Then: should not crash
        XCTAssertNoThrow(sut.playOnce())
    }

    func testStartRepeatingWithNilPlayer_doesNotCrash() {
        // Given: AlertPlayer with nil audioPlayer
        // When: startRepeating is called
        // Then: should not crash
        XCTAssertNoThrow(sut.startRepeating())
    }

    func testStopWithNilPlayer_doesNotCrash() {
        // Given: AlertPlayer with nil audioPlayer
        // When: stop is called
        // Then: should not crash
        XCTAssertNoThrow(sut.stop())
    }

    func testIsPlayingWithNilPlayer_returnsFalse() {
        // Given: AlertPlayer with nil audioPlayer
        // Then: isPlaying should be false
        XCTAssertFalse(sut.isPlaying)
    }
}