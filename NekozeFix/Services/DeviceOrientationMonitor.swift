import UIKit
import AVFoundation

/// サービス層: デバイスの向きの監視と回転検出。
/// design.md の "DeviceOrientationMonitor" セクション参照。

final class DeviceOrientationMonitor: ObservableObject {
    // MARK: - 公開プロパティ

    @Published private(set) var currentVideoOrientation: AVCaptureVideoOrientation = .portrait
    @Published private(set) var isRotating = false

    // MARK: - プライベートプロパティ

    private var rotationTimer: Timer?
    private let notificationCenter = NotificationCenter.default

    // MARK: - 初期化

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - パブリックメソッド

    /// デバイスの向きの変化の監視を開始します
    func startMonitoring() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        notificationCenter.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        _ = updateOrientation()
    }

    /// デバイスの向きの変化の監視を停止します
    func stopMonitoring() {
        notificationCenter.removeObserver(
            self,
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        rotationTimer?.invalidate()
        rotationTimer = nil
    }

    // MARK: - プライベートメソッド

    @objc private func deviceOrientationDidChange() {
        // 既存の回転タイマーをキャンセル
        rotationTimer?.invalidate()

        // 回転中としてマーク
        isRotating = true

        // 現在の向きを更新
        let orientationChanged = updateOrientation()


        // 意味のある向きの変化があった場合のみ5秒タイマーを開始
        // (face-up/face-down は早期リターンするため含まない)
        if orientationChanged {
            rotationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isRotating = false
                }
            }
        } else {
            // Face-up/face-down: 即座に回転完了
            isRotating = false
        }
    }

    private func updateOrientation() -> Bool {
        let deviceOrientation = UIDevice.current.orientation
        let newOrientation: AVCaptureVideoOrientation

        switch deviceOrientation {
        case .portrait:
            newOrientation = .portrait
        case .portraitUpsideDown:
            newOrientation = .portraitUpsideDown
        case .landscapeLeft:
            newOrientation = .landscapeRight
        case .landscapeRight:
            newOrientation = .landscapeLeft
        default:
            // 起動直後など .unknown の場合は windowScene から推定
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
               let raw = AVCaptureVideoOrientation(rawValue: scene.interfaceOrientation.rawValue) {
                newOrientation = raw
            } else {
                return false
            }
        }

        currentVideoOrientation = newOrientation
        return true
    }
}