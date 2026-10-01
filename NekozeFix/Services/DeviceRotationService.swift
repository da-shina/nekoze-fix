import AVFoundation
import Combine
import Foundation

/// サービス層: 回転角の取得・配信・再生成の単一所有者。
///
/// design.md「DeviceRotationService（新設）」参照。
/// Requirements 1.1, 2.1, 2.2, 3.1, 3.2, 4.1。
///
/// - coordinator インスタンスの保持・破棄は本サービスが所有する。生成・再生成の
///   契機は Session が通知する：device 確定時（カメラ構成時）とプレビュー層出現時。
///   coordinator 初期化用のプレビュー層インスタンスは Session が生成して View へ
///   注入する（所有権は Session。View 側で生成しない）。
/// - 公開 API の `previewLayer` は所有権規律により `AVCaptureVideoPreviewLayer?` に
///   絞り、coordinator 初期化子（SDK 上の型は `CALayer?`）へ upcast して渡す
///   （tasks.md Implementation Notes：1.2 で確定）。
/// - preview 用・capture 用の回転角（度）を `@Published` で配信する。KVO 通知は
///   Apple 保証でメイン配送であり、書込みもメインで行う。最新値の上書きのみ。
/// - デバイス姿勢不明時はイベントを発火せず直前の有効角を保持し、nil や推測角を
///   流さない（coordinator は horizon-level 角を常時返すため実機では不明事象は
///   到達しない想定。不明時維持は 5.2 の実機 smoke で確認し、TestDouble 再現は行わない）。
/// - UIDevice 通知の購読・自前換算表・フォールバック推定を持たない。
/// - start は監視・校正開始時に呼ばれ、stop は停止・背景移行時に呼ばれる
///   （Motion 起停と同一則。結線は task 4.1）。プロセス内メモリのみで永続化しない。
final class DeviceRotationService: ObservableObject {
    /// preview 用回転角（度）。KVO 由来でメイン配送される。
    @Published private(set) var previewRotationAngle: CGFloat
    /// capture 用回転角（度）。KVO 由来でメイン配送される。
    @Published private(set) var captureRotationAngle: CGFloat
    /// Session 駆動のライフサイクル状態（start 済み・未 stop）。テストは @testable で読む。
    /// MotionService の `isRunning` と同一役であり、名称は TestDouble（Fake）の
    /// `isStarted` に合わせてある。
    private(set) var isStarted = false

    private var coordinator: AVCaptureDevice.RotationCoordinator
    private var observations: [NSKeyValueObservation] = []

    /// - Parameters:
    ///   - device: 監視対象のビデオデバイス（coordinator が弱参照で保持する）。
    ///   - previewLayer: Session が生成したプレビュー層（nil 可。nil 時は SDK 仕様で
    ///     preview 角として 0° を返す）。呼び出しはメインを想定する（KVO 配送と同一）。
    init(device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer?) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.coordinator = coordinator
        self.previewRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        self.captureRotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
    }

    /// カメラ確定時・プレビュー層出現時に Session が呼ぶ再生成。旧 coordinator を
    /// 破棄し、新デバイスの coordinator を所有し直して新デバイスの現在角を配信する。
    func recreate(for device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer?) {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.coordinator = coordinator
        publish(
            preview: coordinator.videoRotationAngleForHorizonLevelPreview,
            capture: coordinator.videoRotationAngleForHorizonLevelCapture
        )
        if isStarted {
            beginObserving()
        }
    }

    /// 監視・校正開始時に呼ぶ（Motion 起停と同一則）。二重 start は無視する。
    func start() {
        guard !isStarted else { return }
        isStarted = true
        beginObserving()
        publish(
            preview: coordinator.videoRotationAngleForHorizonLevelPreview,
            capture: coordinator.videoRotationAngleForHorizonLevelCapture
        )
    }

    /// 監視停止・背景移行時に呼ぶ（Motion 起停と同一則）。保持角は破棄せず維持する
    /// （停止中の無イベント＝直前有効角の保持。不明時維持則と同一の保持動作）。
    func stop() {
        isStarted = false
        observations.forEach { $0.invalidate() }
        observations.removeAll()
    }

    // MARK: - KVO

    /// coordinator の両角を購読する。KVO は Apple 保証でメイン配送される。
    /// 通知が来ない間は何も発火せず直前有効角を保持する（不明時維持）。
    /// 推測値の合成・フォールバックは行わない。
    private func beginObserving() {
        let previewObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] _, change in
            guard let self, let angle = change.newValue else { return }
            self.publishPreview(angle)
        }
        let captureObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] _, change in
            guard let self, let angle = change.newValue else { return }
            self.publishCapture(angle)
        }
        observations = [previewObservation, captureObservation]
    }

    private func publish(preview: CGFloat, capture: CGFloat) {
        if Thread.isMainThread {
            previewRotationAngle = preview
            captureRotationAngle = capture
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.previewRotationAngle = preview
                self?.captureRotationAngle = capture
            }
        }
    }

    private func publishPreview(_ angle: CGFloat) {
        if Thread.isMainThread {
            previewRotationAngle = angle
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.previewRotationAngle = angle
            }
        }
    }

    private func publishCapture(_ angle: CGFloat) {
        if Thread.isMainThread {
            captureRotationAngle = angle
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.captureRotationAngle = angle
            }
        }
    }
}
