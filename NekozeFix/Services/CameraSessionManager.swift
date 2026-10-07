import AVFoundation
import UIKit

/// フロントカメラのセッション管理とパーミッション。
///
/// `.vga640x480` プリセット (4:3)、シリアルキャプチャキュー、
/// 非同期認証による AVCaptureSession の管理。
/// 4:3 は 720p (16:9) と異なりセンサー上下を切り落とさないため、
/// 横向き使用時の垂直画角を確保できる（ADR 0020）。
///
/// 設計参照: design.md の "CameraSessionManager" セクション。
final class CameraSessionManager: NSObject, ObservableObject, @unchecked Sendable {
    // MARK: - 公開プロパティ

    @Published private(set) var authorization: CameraAuthorization = .notDetermined

    // MARK: - パブリックプロパティ

    let captureSession = AVCaptureSession()

    /// テスト注入用接続シーム。nil 時は `videoOutput` の実接続を使う。
    /// `@testable` 経由でテストが Fake を注入する。
    var rotationConnectionForTesting: VideoRotationConnection?

    /// カメラ確定デバイスの通知先（4.1 実結線）。
    /// Session が設定し、coordinator 再生成（同一所有層）に使う。
    /// configureSession 内・sessionQueue 上で同期呼出しする。
    /// Session 側は Main へ hop して受けるため、本呼出しは構成ブロックを塞がない。
    var deviceFinalizedHandler: ((AVCaptureDevice) -> Void)?

    /// 直近の有効 capture 角（度）。再構成時（カメラ切替）の再適用用に保持する。
    private(set) var lastCaptureRotationAngle: CGFloat = 0

    /// Session から転送される capture 用回転角（度）を data-output 接続へ適用する。
    /// preview 接続には触らない（`CameraPreviewView` が所有）。
    /// 対応可否を実行時判定し、非対応時は適用を見送る（退行則。クラッシュさせない）。
    /// Vision へ渡すバッファ向き（`.up` 固定）は `PostureSessionManager.captureOutput` 側で保つ。
    func updateCaptureRotationAngle(_ degrees: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.lastCaptureRotationAngle = degrees
            self.applyCaptureRotationAngleLocked(degrees)
        }
    }

    /// テスト用フラッシュ：`sessionQueue` に積まれた保留作業の完了を待つ。
    func flushRotationWorkForTesting() {
        sessionQueue.sync {}
    }

    /// 前面／背面切替時のミラー設定。前面のみミラー有効にする。
    /// `configureSession` からも呼ばれる（前面ミラー設定は維持）。
    /// デバイス姿勢の推測は行わない（前面／背面の位置情報のみで決定）。
    func updateMirrorSetting(for position: AVCaptureDevice.Position) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyMirrorSettingLocked(for: position)
        }
    }

    /// `sessionQueue` 上でのみ呼ぶ回転適用本体。実行時に対応可否を判定し、
    /// 非対応時は見送る（退行則）。preview 接続には触らない。
    private func applyCaptureRotationAngleLocked(_ degrees: CGFloat) {
        withVideoConnection {
            guard $0.isVideoRotationAngleSupported(degrees) else { return }
            $0.videoRotationAngle = degrees
        }
    }

    /// `sessionQueue` 上でのみ呼ぶミラー適用本体。前面のみ有効化する。
    private func applyMirrorSettingLocked(for position: AVCaptureDevice.Position) {
        withVideoConnection {
            if $0.isVideoMirroringSupported {
                $0.isVideoMirrored = (position == .front)
            }
        }
    }

    /// data-output 接続の取得を一本化する。テスト注入があればそれを使い、
    /// なければ `videoOutput` の実接続を使う。不在時はなにもしない。
    private func withVideoConnection(_ body: (any VideoRotationConnection) -> Void) {
        guard let connection: VideoRotationConnection = self.rotationConnectionForTesting
            ?? self.videoOutput?.connection(with: .video) else { return }
        body(connection)
    }

    // MARK: - プライベートプロパティ

    private let sessionQueue = DispatchQueue(label: "com.nekozefix.camera.session")
    /// Vision推論専用キュー。制御系（sessionQueue）と分離し、人物ありの高負荷
    /// フレームが回転角適用・カメラ再構成を head-of-line ブロックするのを防ぐ。
    /// `alwaysDiscardsLateVideoFrames = true` と併せ、処理中の後続フレームは
    /// AVFoundation 側で間引かれるため滞留しない。
    private let detectionQueue = DispatchQueue(label: "com.nekozefix.camera.detection")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var sampleBufferDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?

    // MARK: - 認証

    func requestAuthorization() async -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run {
                self.authorization = granted ? .authorized : .denied
            }
            return authorization
        case .authorized:
            await MainActor.run {
                self.authorization = .authorized
            }
            return .authorized
        case .denied, .restricted, _:
            await MainActor.run {
                self.authorization = .denied
            }
            return .denied
        }
    }

    // MARK: - セッション管理

    func start(position: AVCaptureDevice.Position = .front) async throws {
        guard authorization == .authorized else {
            throw CameraError.notAuthorized
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: CameraError.sessionConfigurationFailed)
                    return
                }

                do {
                    try self.configureSession(position: position)
                    self.captureSession.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    // MARK: - サンプルバッファデリゲート

    func setSampleBufferDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        sessionQueue.async { [weak self] in
            self?.sampleBufferDelegate = delegate
        }
    }

    // MARK: - プライベートメソッド

    private func configureSession(position: AVCaptureDevice.Position) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // 横向きの垂直画角確保のため 4:3 の VGA を優先する。
        // 720p (16:9) はセンサー上下を切り落とし、横向きで肩が画角外になる（ADR 0020）。
        // 非対応機種では従来の .high に退行する。
        if captureSession.canSetSessionPreset(.vga640x480) {
            captureSession.sessionPreset = .vga640x480
        } else {
            captureSession.sessionPreset = .high
        }

        // 既存の入力を削除
        captureSession.inputs.forEach { captureSession.removeInput($0) }

        // 指定された位置のカメラを追加
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CameraError.cameraNotAvailable
        }

        // 4.1 実結線：確定デバイスを Session へ通知する（coordinator 再生成用）。
        // 順序・キュー保証：本通知は sessionQueue 上の構成ブロック内で発行され、
        // Session 側の recreate→publish→capture角転送も同一 sessionQueue へ FIFO 投入されるため、
        // 構成（直前角の再適用）→新角適用の順序が確定し、最終値は最新角になる。
        // ハンドラは Main へ hop するため構成ブロックを塞がない。
        deviceFinalizedHandler?(camera)

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                throw CameraError.sessionConfigurationFailed
            }
        } catch {
            throw CameraError.sessionConfigurationFailed
        }

        // ビデオ出力の設定
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        // 検出コールバックは detectionQueue で受け、制御系 sessionQueue を塞がない。
        // 人物ありの高負荷推論中も回転角適用・カメラ再構成が即時実行される。
        output.setSampleBufferDelegate(sampleBufferDelegate, queue: detectionQueue)

        // 既存の出力を削除
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            self.videoOutput = output

            // data-output 接続へ直近有効角を再適用する（カメラ切替時の継続）。
            // preview 接続には触らない。デバイス姿勢の推測は行わない。
            // 対応可否は実行時判定し、非対応時は見送る（退行則）。
            // 前面ミラー設定は維持する。
            applyCaptureRotationAngleLocked(self.lastCaptureRotationAngle)
            applyMirrorSettingLocked(for: position)
        } else {
            throw CameraError.sessionConfigurationFailed
        }
    }
}

// MARK: - エラー

enum CameraError: LocalizedError {
    case notAuthorized
    case cameraNotAvailable
    case sessionConfigurationFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "カメラが許可されていません"
        case .cameraNotAvailable:
            return "カメラが利用できません"
        case .sessionConfigurationFailed:
            return "カメラセッションの構成に失敗しました"
        }
    }
}
