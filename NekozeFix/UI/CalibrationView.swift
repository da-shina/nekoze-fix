import SwiftUI
import Combine

/// UI layer: calibration guidance, accumulation timer, person-missing message.
/// See design.md "UI Components" - CalibrationView.

struct CalibrationView: View {
    // MARK: - Environment

    @EnvironmentObject private var sessionManager: PostureSessionManager

    // MARK: - State

    @State private var timerRemaining = 3.0
    @State private var isPersonDetected = false
    @State private var showingPersonMissing = false
    @State private var progressMessage = "3秒間姿勢を保持してください"
    @State private var cancellables = Set<AnyCancellable>()
    @State private var timer: Timer?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 32) {
            // Timer display
            Text("\(Int(timerRemaining))秒")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)

            // Status indicator
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)

                Text(isPersonDetected ? "検出中" : "検出失敗")
                    .foregroundColor(isPersonDetected ? .green : .red)
            }

            // Message area
            VStack(spacing: 16) {
                if showingPersonMissing {
                    Text("人を検出できません\nもう一度姿勢を保持してください")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text(progressMessage)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            // Action button
            Button(action: recalibrate) {
                Text("再実行")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color(.systemBackground))
        .navigationBarTitle("校正", displayMode: .inline)
        .onAppear {
            setupTimer()
            setupObservers()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - Private Methods

    private func setupTimer() {
        timer?.invalidate()
        timerRemaining = 3.0

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.timerRemaining > 0 {
                self.timerRemaining -= 0.5
            }
        }
    }

    private func setupObservers() {
        // Observe person detection state
        sessionManager.$snapshot
            .map { $0.isPersonDetected }
            .sink { [weak self] detected in
                self?.isPersonDetected = detected
                self?.showingPersonMissing = !detected
                self?.progressMessage = detected ? "姿勢を保持中..." : "人を検出できません\n姿勢を保持してください"
            }
            .store(in: &cancellables)
    }

    private func recalibrate() {
        timer?.invalidate()
        timerRemaining = 3.0
        isPersonDetected = false
        showingPersonMissing = false
        progressMessage = "3秒間姿勢を保持してください"
        setupTimer()
    }
}

// MARK: - Preview

struct CalibrationView_Previews: PreviewProvider {
    static var previews: some View {
        CalibrationView()
            .environmentObject(PostureSessionManager())
            .previewDisplayName("Calibration - Ready")
    }
}
