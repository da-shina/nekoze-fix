import UIKit

/// Services layer: app foreground/background lifecycle observation.
/// See design.md "AppLifecycleObserver" section.

final class AppLifecycleObserver: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var isActive = true

    // MARK: - Private Properties

    private let notificationCenter = NotificationCenter.default
    private var onBackground: (() -> Void)?
    private var onForeground: (() -> Void)?

    // MARK: - Initialization

    init() {
        startObserving()
    }

    deinit {
        stopObserving()
    }

    // MARK: - Public Methods

    /// Starts observing app lifecycle events
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

    /// Stops observing app lifecycle events
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

    /// Sets the callback for background transitions
    /// - Parameter callback: Closure to execute when app enters background
    func onBackgroundTransition(_ callback: @escaping () -> Void) {
        onBackground = callback
    }

    /// Sets the callback for foreground transitions
    /// - Parameter callback: Closure to execute when app becomes active
    func onForegroundTransition(_ callback: @escaping () -> Void) {
        onForeground = callback
    }

    // MARK: - Private Methods

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