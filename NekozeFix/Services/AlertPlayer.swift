import AVFoundation

/// Services layer: notification sound playback with .playback audio category.
/// See design.md "AlertPlayer" section.

final class AlertPlayer {
    // MARK: - Properties

    private var audioPlayer: AVAudioPlayer?
    private var repeatingTimer: Timer?
    private let soundURL: URL
    private let audioSession = AVAudioSession.sharedInstance()

    // MARK: - Initialization

    /// Preloads the alert sound during session configuration
    /// - Parameter soundURL: URL to the alert sound file
    init(soundURL: URL) {
        self.soundURL = soundURL
        configureAudioSession()
    }

    // MARK: - Public Methods

    /// Configures the alert player with the alert sound
    /// - Throws: if audio file cannot be loaded
    func configureSession() throws {
        let player = try AVAudioPlayer(contentsOf: soundURL)
        player.prepareToPlay()
        self.audioPlayer = player
    }

    /// Plays the alert sound once immediately
    func playOnce() {
        guard let player = audioPlayer else { return }
        player.stop()
        player.currentTime = 0
        player.play()
    }

    /// Starts repeating the alert at 30-second intervals
    func startRepeating() {
        guard let player = audioPlayer else { return }
        // Stop any existing timer
        repeatingTimer?.invalidate()

        // Play immediately
        player.stop()
        player.currentTime = 0
        player.play()

        // Start 30-second interval timer
        repeatingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.playOnce()
        }
    }

    /// Stops any currently playing alert sound immediately
    func stop() {
        audioPlayer?.stop()
        repeatingTimer?.invalidate()
        repeatingTimer = nil
    }

    /// Checks if an alert sound is currently playing
    /// - Returns: true if sound is playing, false otherwise
    var isPlaying: Bool {
        return audioPlayer?.isPlaying ?? false
    }

    // MARK: - Private Methods

    private func configureAudioSession() {
        do {
            try audioSession.setCategory(.playback, options: .duckOthers)
            try audioSession.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
}