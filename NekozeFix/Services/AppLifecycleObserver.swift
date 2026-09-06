import UIKit

/// サービス層: アプリのフォアグラウンド/バックグラウンドのライフサイクル監視。
/// design.md の "AppLifecycleObserver" セクション参照。

final class AppLifecycleObserver: ObservableObject {
    // MARK: - 公開プロパティ

    @Published private(set) var isActive = true

    // MARK: - プライベートプロパティ

    private let notificationCenter = NotificationCenter.default
    private var onBackground: (() -> Void)?
    private var onForeground: (() -> Void)?

    // MARK: - 初期化

    init() {
        startObserving()
    }

    deinit {
        stopObserving()
    }

    // MARK: - パブリックメソッド

    /// アプリのライフサイクルイベントの監視を開始します
    func startObserving() {
        notificationCenter.addObserver(
            self,
            selector: #selector(appDidChangeActive),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(appDidChangeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// アプリのライフサイクルイベントの監視を停止します
    func stopObserving() {
        notificationCenter.removeObserver(
            self,
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        notificationCenter.removeObserver(
            self,
            name:UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// バックグラウンド遷移時のコールバックを設定します
    /// - Parameter callback: アプリがバックグラウンドになった時に実行するクロージャ
    func onBackgroundTransition(_ callback: @escaping () -> Void) {
        onBackground = callback
    }

    /// フォアグラウンド遷移時のコールバックを設定します
    /// - Parameter callback: アプリがアクティブになった時に実行するクロージャ
    func onForegroundTransition(_ callback: @escaping () -> Void) {
        onForeground = callback
    }

    // MARK: - プライベートメソッド

    @objc private func appDidChangeActive(_ notification: Notification) {
        let name = notification.name

        if name ==UIApplication.didEnterBackgroundNotification {
            isActive = false
            onBackground?()
        } else if name ==UIApplication.didBecomeActiveNotification {
            isActive = true
            onForeground?()
        }
    }
}