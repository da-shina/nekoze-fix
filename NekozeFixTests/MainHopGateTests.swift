import XCTest
@testable import NekozeFix

final class MainHopGateTests: XCTestCase {
    func testGateSkeleton_compilesAndResets() {
        var gate = MainHopGate()
        gate.reset()
        XCTAssertEqual(gate.snapshot().submits, 0)
    }
}
