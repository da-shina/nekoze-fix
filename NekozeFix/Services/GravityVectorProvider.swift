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

    /// 現在のビデオ向きに基づき、Vision バッファ座標系（左下原点、上方向 +Y）における物理的な垂直方向（下向き）ベクトルを算出します。
    public func verticalVector(for orientation: AVCaptureVideoOrientation) -> CGPoint {
        guard let g = dataSource.getGravity() else {
            // データ取得不可時はデフォルトの下向きベクトルを返す (Vision座標系で下向きは y = -1)
            return CGPoint(x: 0, y: -1)
        }

        // CMMotionManager の座標系: x=右, y=上, z=画面手前
        // Vision バッファ座標系: x=左→右, y=下→上 (左下原点)

        switch orientation {
        case .portrait:
            // Device X -> Vision X
            // Device Y (up) -> Vision Y (up)
            // 下向きベクトルは Device Y の逆向き
            return CGPoint(x: g.x, y: -g.y)

        case .landscapeLeft:
            // 画像の Top = Device -X
            // 画像の Right = Device +Y
            // Vision X = Device Y
            // Vision Y = Device X
            // 下向きベクトルは Device X の逆向き
            return CGPoint(x: g.y, y: -g.x)

        case .landscapeRight:
            // 画像の Top = Device +X
            // 画像の Right = Device -Y
            // Vision X = -Device Y
            // Vision Y = -Device X
            // 下向きベクトルは Device X の正向き
            return CGPoint(x: -g.y, y: g.x)

        case .portraitUpsideDown:
            // Device X -> Vision -X
            // Device Y (up) -> Vision Y (down)
            // 下向きベクトルは Device Y の正向き
            return CGPoint(x: -g.x, y: g.y)

        @unknown default:
            return CGPoint(x: 0, y: -1)
        }
    }
}
