import AVFoundation

/// サービス層: .playback オーディオカテゴリによる通知音再生。
/// 詳細は design.md "AlertPlayer" セクション参照。

final class AlertPlayer {
    // MARK: - プロパティ

    private var audioPlayer: AVAudioPlayer?
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

    /// 音声を1ループ再生し、終了直後から次のループを繰り返します
    func startRepeating() {
        play(loops: -1)
    }

    /// 現在再生中のアラート音を即座に停止します
    func stop() {
        audioPlayer?.stop()
    }

    private func play(loops: Int) {
        guard let player = audioPlayer else { return }
        player.stop()
        player.currentTime = 0
        player.numberOfLoops = loops
        player.play()
    }

    // MARK: - プライベートメソッド

    private func configureAudioSession() {
        try? audioSession.setCategory(.playback, options: .duckOthers)
        try? audioSession.setActive(true)
    }
}