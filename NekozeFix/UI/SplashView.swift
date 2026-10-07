import SwiftUI

/// UI レイヤー: 起動スプラッシュ（再校正の入口）。
/// idle フェーズの専用画面。提供デザイン準拠:
/// 薄ラベンダー背景 / ダークパープル明朝タイトル / ベクター猫イラスト / パープル角丸ボタン。

struct SplashView: View {
    // MARK: - カラーパレット（画像から抽出）

    private let backgroundColor = Color(red: 0.92, green: 0.91, blue: 0.95)
    private let textColor = Color(red: 0.22, green: 0.12, blue: 0.28)
    private let lineAccentColor = Color(red: 0.38, green: 0.25, blue: 0.48)
    private let buttonBackgroundColor = Color(red: 0.52, green: 0.40, blue: 0.76)

    // MARK: - アクション

    /// 「キャリブレーションを開始」タップ時の処理。
    /// RootView から `sessionManager.startCalibration()` を注入する。
    var onStartCalibration: () -> Void = {}

    // MARK: - 環境

    /// 横向き iPhone では compact になる。縦方向の余白・サイズを切り替える。
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    // MARK: - 本文

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 1. 全画面背景（角丸なしの長方形）
                backgroundColor
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    // 2. タイトル & サブタイトル（太め明朝体）
                    VStack(spacing: 12) {
                        Text("NekozeFix")
                            .font(.custom("HiraMinProN-W6", size: isCompactHeight ? 30 : 38))
                            .fontWeight(.bold)
                            .foregroundColor(textColor)

                        Text("姿勢を守る、猫背フィックス")
                            .font(.custom("HiraMinProN-W6", size: 16))
                            .fontWeight(.bold)
                            .foregroundColor(textColor.opacity(0.85))
                    }
                    .padding(.bottom, isCompactHeight ? 20 : 48)

                    // 3. 猫のベクターイラスト（中央配置）
                    // `CatLaptopVector` SVG アセットを使用。未登録の環境では
                    // プレースホルダー Shape にフォールバックする。
                    // 幅割合だけでは縦短画面で溢れ・大画面で巨大化するため、
                    // 高さ換算と絶対上限 (380pt) を併用する。
                    // SVG は viewBox 側で余白を切り詰め済み (320x182)。
                    catIllustration(width: illustrationWidth(in: geometry))
                        .padding(.bottom, isCompactHeight ? 24 : 64)

                    Spacer(minLength: 0)

                    // 4. アクションボタン（角丸長方形）
                    Button(action: onStartCalibration) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .bold))

                            Text("キャリブレーションを開始")
                                .font(.system(size: 17, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(buttonBackgroundColor)
                        .cornerRadius(16)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, isCompactHeight ? 24 : 48)
                }
            }
        }
    }

    // MARK: - サイズ計算

    /// イラスト幅。幅割合・高さ換算・絶対上限の最小値を取る。
    /// アスペクト (320:182) で高さ予算を幅に換算している。
    /// - iPhone縦: 幅 90% → 絵がボタン幅とほぼ一致（mini 375pt → 枠337pt・絵320pt）
    /// - iPhone横 (812x375): 高さ換算 → 約225pt（溢れない）
    /// - iPad横 (1080x810): 上限 380pt（巨大化しない）
    private func illustrationWidth(in geometry: GeometryProxy) -> CGFloat {
        let aspect: CGFloat = 320 / 182
        let heightBudget: CGFloat = geometry.size.height * (isCompactHeight ? 0.34 : 0.30)
        let byWidth = geometry.size.width * (isCompactHeight ? 0.58 : 0.90)
        let byHeight = heightBudget * aspect
        return min(byWidth, byHeight, 380)
    }

    // MARK: - サブビュー

    /// SVG アセット `CatLaptopVector` があれば `Image`、なければプレースホルダー Shape。
    /// `UIImage(named:)` の存在チェックで切り替える。
    /// SVG 自体の単色フィル (#A98FD8) を活かすため tint は付けない。
    /// - Parameter width: 呼び出し側で算出した幅（高さはアスペクト維持）。
    private func catIllustration(width: CGFloat) -> some View {
        Group {
            if UIImage(named: "CatLaptopVector") != nil {
                Image("CatLaptopVector")
                    .resizable()
                    .scaledToFit()
                    .frame(width: width)
            } else {
                CatLaptopVectorShape()
                    .stroke(lineAccentColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    .frame(width: width, height: width * 180 / 220)
            }
        }
    }
}

// MARK: - 猫+ノートPCのアウトライン（プレースホルダー）

struct CatLaptopVectorShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: CGPoint(x: w * 0.08, y: h * 0.78))
        path.addQuadCurve(to: CGPoint(x: w * 0.28, y: h * 0.25), control: CGPoint(x: w * 0.08, y: h * 0.40))
        path.addQuadCurve(to: CGPoint(x: w * 0.60, y: h * 0.22), control: CGPoint(x: w * 0.42, y: h * 0.12))
        path.addQuadCurve(to: CGPoint(x: w * 0.65, y: h * 0.52), control: CGPoint(x: w * 0.68, y: h * 0.38))
        path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.52))
        path.addLine(to: CGPoint(x: w * 0.74, y: h * 0.78))
        path.addLine(to: CGPoint(x: w * 0.08, y: h * 0.78))

        return path
    }
}

// MARK: - プレビュー

#Preview {
    SplashView()
}
