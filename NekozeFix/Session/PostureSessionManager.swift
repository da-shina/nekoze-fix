import SwiftUI
import Combine

/// セッション層: 姿勢監視セッションの状態マシン。
/// design.md "PostureSessionManager" セクション参照。

@MainActor
final class PostureSessionManager: ObservableObject {
    // MARK: - 公開プロパティ

    @Published private(set) var snapshot: SessionSnapshot

    // MARK: - プライベートプロパティ

    private var cancellables = Set<AnyCancellable>()
    private let cameraManager = CameraSessionManager()

    // MARK: - 初期化

    /// デフォルトのスナップショットで初期化する
    init() {
        self.snapshot = SessionSnapshot()
    }

    // MARK: - 公開メソッド

    /// セッションの初期化を行う
    func bootstrap() async {
        let auth = await cameraManager.requestAuthorization()
        switch auth {
        case .authorized:
            snapshot.phase = .calibrating
        case .denied:
            snapshot.phase = .permissionDenied
        case .notDetermined:
            snapshot.phase = .awaitingPermission
        }
    }

    /// キャリブレーションフェーズに遷移する
    func startCalibration() {
        snapshot.phase = .calibrating
    }

    /// アイドル状態から再キャリブレーションする
    func recalibrate() {
        snapshot.phase = .calibrating
    }

    /// 姿勢監視を開始する
    func startMonitoring() {
        snapshot.phase = .monitoring
        snapshot.isDimmed = false
        snapshot.isRotating = false
        // 監視開始時にゲートをリセットする
        snapshot.slouchGate.reset()
    }

    /// 姿勢監視を停止する
    func stopMonitoring() {
        snapshot.phase = .idle
        snapshot.isDimmed = false
        snapshot.isRotating = false
    }

    /// ディムモードに入る（ブラックスクリーン＋ウェイクロック）
    func enterDimMode() {
        snapshot.isDimmed = true
    }

    /// ディムモードを終了する
    func exitDimMode() {
        snapshot.isDimmed = false
    }

    /// 感度設定を更新する
    func updateSensitivity(_ value: Double) {
        snapshot.sensitivity = max(0.0, min(1.0, value))
    }

    /// 表示される姿勢状態を更新する
    func updatePosture(_ posture: DisplayedPosture) {
        snapshot.displayedPosture = posture
    }

    /// 人検出状態を更新する
    func updatePersonDetected(_ detected: Bool) {
        snapshot.isPersonDetected = detected
    }

    /// フェーズを更新する（外部ステートマシン制御用）
    func updatePhase(_ phase: SessionPhase) {
        snapshot.phase = phase
    }

    /// 監視有効フラグを更新する
    func updateMonitoringEnabled(_ enabled: Bool) {
        snapshot.isMonitoringEnabled = enabled
    }
}