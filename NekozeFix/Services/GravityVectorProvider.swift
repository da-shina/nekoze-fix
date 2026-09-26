import Foundation
import CoreMotion
import AVFoundation

/// Core Motion から重力ベクトルを取得し、カメラ画像平面上の垂直ベクトルに投影するサービス。
/// design.md の "GravityVectorProvider" セクション参照。

public protocol MotionDataSource {
    func getGravity() -> CMAcceleration?
}

public final class CMMotionDataSource: MotionDataSource {
    private let motionManager = CMMotionManager()

    public init() {
        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 1.0 / 30.0
            motionManager.startAccelerometerUpdates()
        }
    }

    public func getGravity() -> CMAcceleration? {
        return motionManager.accelerometerData?.acceleration
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
    }
}

public final class GravityVectorProvider {
    private let dataSource: MotionDataSource

    public init(dataSource: MotionDataSource = CMMotionDataSource()) {
        self.dataSource = dataSource
    }

    /// 現在のビデオ向きに基づき、画像平面上の物理的な垂直方向（下向き）ベクトルを算出します。
    public func verticalVector(for orientation: AVCaptureVideoOrientation) -> CGPoint {
        guard let g = dataSource.getGravity() else {
            // データ取得不可時はデフォルトの下向きベクトルを返す
            return CGPoint(x: 0, y: 1)
        }

        // CMMotionManager の座標系: x=右, y=上, z=画面手前
        // 画像平面の座標系: x=左→右, y=上→下

        switch orientation {
        case .portrait:
            // Device X -> Img X
            // Device Y (up) -> Img Y (up) => Img Y = -Device Y
            return CGPoint(x: g.x, y: -g.y)

        case .landscapeLeft:
            // Top of image = Device -X
            // Right of image = Device +Y
            // Img X = Device Y
            // Img Y = Device X
            return CGPoint(x: g.y, y: g.x)

        case .landscapeRight:
            // Top of image = Device +X
            // Right of image = Device -Y
            // Img X = -Device Y
            // Img Y = -Device X
            return CGPoint(x: -g.y, y: -g.x)

        case .portraitUpsideDown:
            // Device X -> Img -X
            // Device Y (up) -> Img Y (down) => Img Y = Device Y
            return CGPoint(x: -g.x, y: g.y)

        @unknown default:
            return CGPoint(x: 0, y: 1)
        }
    }
}
