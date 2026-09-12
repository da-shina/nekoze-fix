import AVFoundation

/// サービス層: .playback オーディオカテゴリによる通知音再生。
/// 詳細は design.md "AlertPlayer" セクション参照。

final class AlertPlayer {
    // MARK: - プロパティ

    private var audioPlayer: AVAudioPlayer?
    private var repeatingTimer: Timer?
    private let soundURL: URL
    private let audioSession = AVAudioSession.sharedInstance()

    /// 現在再生中かどうか
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    // MARK: - 初期化

    /// セッション設定時にアラート音をプリロードします
    /// - Parameter soundURL: アラートサウンドファイルのURL
    init(soundURL: URL) {
        self.soundURL = soundURL
        configureAudioSession()
    }

    // MARK: - パブリックメソッド

    /// アラートプレイヤーをアラートサウンドで構成します
    /// - Throws: オーディオファイルの読み込みに失敗した場合
    func configureSession() throws {
        let player = try AVAudioPlayer(contentsOf: soundURL)
        player.prepareToPlay()
        self.audioPlayer = player
    }

    /// アラート音を即座に1回だけ再生します
    func playOnce() {
        guard let player = audioPlayer else { return }
        player.stop()
        player.currentTime = 0
        player.play()
    }

    /// 音声を1ループ再生し、終了直後から次のループを繰り返します
    func startRepeating() {
        guard let player = audioPlayer else { return }
        // 既存のタイマーを停止
        repeatingTimer?.invalidate()

        // 即座に再生
        player.stop()
        player.currentTime = 0
        player.play()

        // 音声の実長さと同一間隔で再再生（音切れ・重複なしのシームレスループ）
        let interval = player.duration > 0 ? player.duration : 30.0
        repeatingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.playOnce()
        }
    }

    /// 現在再生中のアラート音を即座に停止します
    func stop() {
        audioPlayer?.stop()
        repeatingTimer?.invalidate()
        repeatingTimer = nil
    }

    // MARK: - プライベートメソッド

    private func configureAudioSession() {
        do {
            try audioSession.setCategory(.playback, options: .duckOthers)
            try audioSession.setActive(true)
        } catch {
            print("オーディオセッションの構成に失敗しました: \(error)")
        }
    }
}