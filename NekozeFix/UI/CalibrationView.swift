import SwiftUI
import Combine
import AVFoundation

/// UI レイヤー: 校正ガイド、集約タイマー、人検出メッセージ。
/// design.md の "UI Components" - CalibrationView を参照。

struct CalibrationView: View {
    // MARK: - 環境

    @EnvironmentObject private var sessionManager: PostureSessionManager
    @EnvironmentObject private var settingsStore: SettingsStore

    // MARK: - 状態

    @State private var timerRemaining = 3.0
    @State private var isPersonDetected = false
    @State private var showingPersonMissing = false
    @State private var progressMessage = "3秒間姿勢を保持してください"
    @State private var cancellables = Set<AnyCancellable>()
    @State private var timer: Timer?

    // MARK: - 本文

    var body: some View {
        ZStack {
            // 背景にカメラプレビューを表示
            CameraPreviewView(session: sessionManager.cameraManager.captureSession)
                .ignoresSafeArea()

            // 正しい画角への誘導ガイド
            if sessionManager.snapshot.showGuideline {
                PostureGuidelineOverlay()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // 基準線とポイントの可視化
            CalibrationOverlayView(
                referenceAngle: sessionManager.snapshot.referenceAngle ?? 0.0,
                currentPoints: sessionManager.snapshot.visualizationPoints,
                threshold: sessionManager.snapshot.currentThreshold,
                nearSide: sessionManager.snapshot.nearSide
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                // タイマー表示
                Text("\(Int(timerRemaining))秒")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .shadow(radius: 4)

                // 基準線のオーバーレイ
                ZStack {
                    // カメラプレビューの上に描画するため、ここでは空のViewにして
                    // 実際にはCameraPreviewViewの上のZStackで管理
                }
                .frame(height: 0)


                // ステータス表示
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)

                    Text(isPersonDetected ? "検出中" : "検出失敗")
                        .foregroundColor(isPersonDetected ? .green : .red)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemBackground).opacity(0.7))
                .cornerRadius(20)

                // メッセージエリア
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
                .padding()
                .background(Color(.systemBackground).opacity(0.7))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .center)

                Spacer()

                // 下部コントロールエリア
                VStack(spacing: 24) {
                    // カメラ切り替え
                    HStack {
                        Text("カメラ")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Spacer()

                        Picker("カメラ位置", selection: $settingsStore.cameraPosition) {
                            Text("前面").tag(CameraPosition.front)
                            Text("背面").tag(CameraPosition.back)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                    .padding()
                    .background(Color(.systemBackground).opacity(0.8))
                    .cornerRadius(16)

                    // アクションボタン
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
                .background(Color(.systemBackground).opacity(0.8))
                .cornerRadius(24)
            }
            .padding()
        }
        .navigationBarTitle("校正", displayMode: .inline)
        .onAppear {
            setupTimer()
            setupObservers()
            if sessionManager.snapshot.phase == .calibrating {
                Task {
                    // すでに動作している可能性はあるが、明示的に開始を試みる
                    // PostureSessionManager の startCalibration() 等と同様の処理を呼び出す
                    sessionManager.startCalibration()
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - プライベートメソッド

    private func setupTimer() {
        timer?.invalidate()
        timerRemaining = 3.0

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if self.timerRemaining > 0 {
                self.timerRemaining -= 0.5
            }
        }
    }

    private func setupObservers() {
        // 人検出状態を監視
        sessionManager.$snapshot
            .map { $0.isPersonDetected }
            .sink { [self] detected in
                self.isPersonDetected = detected
                self.showingPersonMissing = !detected
                self.progressMessage = detected ? "姿勢を保持中..." : "人を検出できません\n姿勢を保持してください"
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

// MARK: - プレビュー

struct CalibrationOverlayView: View {
    let referenceAngle: Double
    let currentPoints: [CGPoint]
    let threshold: Double
    let nearSide: Side?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if currentPoints.count >= 2 && currentPoints[0] != .zero && currentPoints[1] != .zero {
                    // 肩のライン (左肩 -> 右肩)
                    Path { path in
                        let pL = normalizePoint(currentPoints[0], in: geometry.size)
                        let pR = normalizePoint(currentPoints[1], in: geometry.size)
                        path.move(to: pL)
                        path.addLine(to: pR)
                    }
                    .stroke(Color.blue, lineWidth: 2)

                    // 肩のポイント
                    ForEach(0..<2) { i in
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                            .position(normalizePoint(currentPoints[i], in: geometry.size))
                    }
                }

                if currentPoints.count >= 4 && currentPoints[2] != .zero && currentPoints[3] != .zero {
                    // 現在の耳と肩を結ぶ線 (近傍耳 -> 近傍肩)
                    Path { path in
                        let pE = normalizePoint(currentPoints[2], in: geometry.size)
                        let pS = normalizePoint(currentPoints[3], in: geometry.size)
                        path.move(to: pE)
                        path.addLine(to: pS)
                    }
                    .stroke(Color.yellow, lineWidth: 3)
                }

                // 基準となる直線
                Path { path in
                    var startPoint = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

                    if currentPoints.count >= 4 && currentPoints[3] != .zero {
                        // 近傍肩の座標を起点にする (currentPoints[3]が近傍肩)
                        startPoint = normalizePoint(currentPoints[3], in: geometry.size)
                    }

                    let length: CGFloat = 200
                    let radians = referenceAngle * .pi / 180.0

                    // nearSide に基づいてX方向を決定
                    let xDirection: CGFloat = (nearSide == .left) ? -1.0 : 1.0

                    let end = CGPoint(
                        x: startPoint.x + (xDirection * length * sin(radians)),
                        y: startPoint.y - length * cos(radians)
                    )
                    path.move(to: startPoint)
                    path.addLine(to: end)
                }
                .stroke(Color.green, lineWidth: 4)
            }
        }
    }

    /// Vision座標 (0-1, 左下原点) を SwiftUI座標 (左上原点, AspectFill補正済) に変換
    private func normalizePoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        // 1. Y軸反転 (Vision: 左下原点 -> SwiftUI: 左上原点)
        let visionX = point.x
        let visionY = 1.0 - point.y

        // 2. AspectFill 補正
        // 映像の想定アスペクト比 (4:3)
        let imageAR: CGFloat = 4.0 / 3.0
        let viewAR = size.width / size.height

        var sx: CGFloat = 1.0
        var sy: CGFloat = 1.0

        if viewAR > imageAR {
            // 画面の方が横に長い -> 左右はぴったり、上下がクロップされる
            // scale = Wv / Wi -> s_x = 1, s_y = (Hi * scale) / Hv = (Hi * Wv/Wi) / Hv = viewAR / imageAR
            sx = 1.0
            sy = viewAR / imageAR
        } else if viewAR < imageAR {
            // 画面の方が縦に長い -> 上下はぴったり、左右がクロップされる
            // scale = Hv / Hi -> s_y = 1, s_x = (Wi * scale) / Wv = (Wi * Hv/Hi) / Wv = imageAR / viewAR
            sx = imageAR / viewAR
            sy = 1.0
        }

        // 最終的な正規化座標 (0...1)
        let normX = visionX * sx + (1.0 - sx) / 2.0
        let normY = visionY * sy + (1.0 - sy) / 2.0

        // 画面サイズに変換
        return CGPoint(
            x: normX * size.width,
            y: normY * size.height
        )
    }
}

struct CalibrationView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            CalibrationView()
                .environmentObject(PostureSessionManager())
                .environmentObject(SettingsStore())
                .previewDisplayName("校正 - 準備完了")
        }
    }
}
