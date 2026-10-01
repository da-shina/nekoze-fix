import AVFoundation
import UIKit

/// data-output 接続の回転適用に使う接続シーム（テスト容易性）。
/// 本番は `AVCaptureConnection` が適合する。テストは Fake を注入する。
/// simulator には video デバイスが存在しないため、単体テストは
/// `rotationConnectionForTesting` へ Fake を注入して分離検証する（実転送結線は task 4.1）。
protocol CaptureVideoRotationConnection: AnyObject {
    func isVideoRotationAngleSupported(_ videoRotationAngle: CGFloat) -> Bool
    var videoRotationAngle: CGFloat { get set }
    var isVideoMirroringSupported: Bool { get }
    var isVideoMirrored: Bool { get set }
}

extension AVCaptureConnection: CaptureVideoRotationConnection {}

/// フロントカメラのセッション管理とパーミッション。
///
/// `.high` プリセット (720p)、シリアルキャプチャキュー、
/// 非同期認証による AVCaptureSession の管理。
///
/// 設計参照: design.md の "CameraSessionManager" セクション。
final class CameraSessionManager: NSObject, ObservableObject, @unchecked Sendable {
    // MARK: - 公開プロパティ

    @Published private(set) var authorization: CameraAuthorization = .notDetermined

    // MARK: - パブリックプロパティ

    let captureSession = AVCaptureSession()

    /// テスト注入用接続シーム。nil 時は `videoOutput` の実接続を使う。
    /// `@testable` 経由でテストが Fake を注入する。
    var rotationConnectionForTesting: CaptureVideoRotationConnection?

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
        let connection: CaptureVideoRotationConnection? = self.rotationConnectionForTesting
            ?? self.videoOutput?.connection(with: .video)
        guard let connection else { return }
        guard connection.isVideoRotationAngleSupported(degrees) else { return }
        connection.videoRotationAngle = degrees
    }

    /// `sessionQueue` 上でのみ呼ぶミラー適用本体。前面のみ有効化する。
    private func applyMirrorSettingLocked(for position: AVCaptureDevice.Position) {
        let connection: CaptureVideoRotationConnection? = self.rotationConnectionForTesting
            ?? self.videoOutput?.connection(with: .video)
        guard let connection else { return }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = (position == .front)
        }
    }

    // MARK: - プライベートプロパティ

    private let sessionQueue = DispatchQueue(label: "com.nekozefix.camera.session")
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
        case .denied, .restricted:
            await MainActor.run {
                self.authorization = .denied
            }
            return .denied
        @unknown default:
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

        captureSession.sessionPreset = .high  // 720p

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
        output.setSampleBufferDelegate(sampleBufferDelegate, queue: sessionQueue)

        // 既存の出力を削除
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            self.videoOutput = output

            // data-output 接続へ直近有効角を再適用する（カメラ切替時の継続）。
            // preview 接続には触らない。デバイス姿勢の推測は行わない。
            // 対応可否は実行時判定し、非対応時は見送る（退行則）。
            // 前面ミラー設定は維持する。
            let connection: CaptureVideoRotationConnection? = self.rotationConnectionForTesting
                ?? output.connection(with: .video)
            if let connection {
                if connection.isVideoRotationAngleSupported(self.lastCaptureRotationAngle) {
                    connection.videoRotationAngle = self.lastCaptureRotationAngle
                }
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = (position == .front)
                }
            }
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
