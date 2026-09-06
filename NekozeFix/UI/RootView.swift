import SwiftUI

/// UI layer: root view switching between permission/calibration/monitor phases.
/// See design.md "UI Components" - RootView.

struct RootView: View {
    // MARK: - Environment

    @EnvironmentObject private var sessionManager: PostureSessionManager

    // MARK: - Body

    var body: some View {
        Group {
            switch snapshot.phase {
            case .awaitingPermission:
                PermissionView()
            case .calibrating:
                CalibrationView()
            case .monitoring:
                MonitorView()
            case .idle:
                PermissionView()
            case .rotating:
                MonitorView()
                    .environmentObject(DeviceOrientationMonitor())
            @unknown default:
                PermissionView()
            }
        }
        .onAppear {
            Task {
                await sessionManager.bootstrap()
            }
        }
    }

    // MARK: - Computed Properties

    private var snapshot: SessionSnapshot {
        sessionManager.snapshot
    }
}

// MARK: - Preview

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environmentObject(PostureSessionManager())
    }
}