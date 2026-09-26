import SwiftUI
import AVFoundation

/// 姿勢検知のポイントとラインを可視化するオーバーレイ。
struct PostureOverlayView: View {
    enum Mode {
        case reference // 確定時の姿勢 (グレー)
        case current   // 現在の姿勢 (カラー)
    }

    // MARK: - Constants
    private let pointSize: CGFloat = 12
    private let shoulderLineWidth: CGFloat = 4
    private let nearSideLineWidth: CGFloat = 5
    private let guidelineLength: CGFloat = 200
    private let guidelineLineWidthReference: CGFloat = 3
    private let guidelineLineWidthCurrent: CGFloat = 5

    let mode: Mode
    let verticalVector: CGPoint
    let currentPoints: [CGPoint]
    let nearSide: Side?
    /// 前面カメラ等でプレビューがミラー表示されているか。
    /// Vision 座標の x 反転と緑線方向の決定に使用。
    var isMirrored: Bool = true
    /// キャプチャ画像のアスペクト比（バッファ実寸基準。ポートレート前提）
    var imageAspectRatio: CGFloat = 4.0 / 3.0
    /// 現在のビデオ向き。AspectFit 補正の AR 計算に使用。
    var videoOrientation: AVCaptureVideoOrientation = .portrait

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                let isRef = mode == .reference
                let shoulderColor = isRef ? Color.gray.opacity(0.5) : Color.blue
                let earColor = isRef ? Color.gray.opacity(0.5) : Color.green
                let lineColor = isRef ? Color.gray.opacity(0.3) : Color.yellow
                let guidelineColor = isRef ? Color.gray.opacity(0.6) : Color.green

                // 肩のライン (両肩そろったときのみ)
                if currentPoints.count >= 2 && currentPoints[0] != .zero && currentPoints[1] != .zero {
                    Path { path in
                        let pL = normalizePoint(currentPoints[0], in: geometry.size)
                        let pR = normalizePoint(currentPoints[1], in: geometry.size)
                        path.move(to: pL)
                        path.addLine(to: pR)
                    }
                    .stroke(shoulderColor, lineWidth: shoulderLineWidth)
                }

                // 肩のポイント (左右それぞれ、検出できた方だけ表示)
                ForEach(0..<2, id: \.self) { i in
                    if i < currentPoints.count && currentPoints[i] != .zero {
                        Circle()
                            .fill(shoulderColor)
                            .frame(width: pointSize, height: pointSize)
                            .position(normalizePoint(currentPoints[i], in: geometry.size))
                    }
                }

                // 耳のポイント (左右それぞれ、検出できた方だけ表示)
                ForEach(2..<4, id: \.self) { i in
                    if i < currentPoints.count && currentPoints[i] != .zero {
                        Circle()
                            .fill(earColor)
                            .frame(width: pointSize, height: pointSize)
                            .position(normalizePoint(currentPoints[i], in: geometry.size))
                    }
                }

                if currentPoints.count >= 6 && currentPoints[4] != .zero && currentPoints[5] != .zero {
                    // 耳と肩を結ぶ線
                    Path { path in
                        let pE = normalizePoint(currentPoints[4], in: geometry.size)
                        let pS = normalizePoint(currentPoints[5], in: geometry.size)
                        path.move(to: pE)
                        path.addLine(to: pS)
                    }
                    .stroke(lineColor, lineWidth: nearSideLineWidth)
                }

                // 物理的垂直ガイドライン
                if currentPoints.count >= 6 && currentPoints[5] != .zero {
                    drawVerticalGuideline(in: geometry.size, color: guidelineColor, isReference: isRef)
                }
            }
        }
    }

    /// 物理的垂直方向を示すガイドラインを描画
    @ViewBuilder
    private func drawVerticalGuideline(in size: CGSize, color: Color, isReference: Bool) -> some View {
        let startPoint = normalizePoint(currentPoints[5], in: size)

        // verticalVector は正規化座標系 (0.0-1.0) の方向ベクトル
        // View 座標系へ変換するため、アスペクト比を考慮したスケールを適用
        let viewAR = size.width / size.height
        let imageAR = imageAspectRatio

        // ミラーリング対応: 前面カメラの場合、X成分を反転させる
        let vx = isMirrored ? -verticalVector.x : verticalVector.x
        let vy = verticalVector.y

        // 座標系変換: Vision (y-down) -> View (y-down).
        // verticalVector は重力方向 (下向き) なので vy は正。
        // View 座標では下向きが正なので vy はそのまま。
        let sx = viewAR > imageAR ? imageAR / viewAR : 1.0
        let sy = viewAR < imageAR ? viewAR / imageAR : 1.0

        let scaledVX = vx * sx * size.width
        let scaledVY = vy * sy * size.height

        // ベクトルの長さを正規化して指定の length に調整
        let mag = hypot(scaledVX, scaledVY)
        let unitX = mag > 0 ? scaledVX / mag : 0
        let unitY = mag > 0 ? scaledVY / mag : 1

        let end = CGPoint(
            x: startPoint.x + unitX * guidelineLength,
            y: startPoint.y + unitY * guidelineLength
        )

        Path { path in
            path.move(to: startPoint)
            path.addLine(to: end)
        }
        .stroke(color, lineWidth: isReference ? guidelineLineWidthReference : guidelineLineWidthCurrent)
    }

    /// 座標正規化関数
    private func normalizePoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        // ミラーリング対応: X座標を反転
        let screenX = isMirrored ? 1.0 - point.x : point.x
        // Vision (y-down) は SwiftUI (y-down) と一致するため反転不要
        let screenY = point.y

        let imageAR = imageAspectRatio
        let viewAR = size.width / size.height
        var sx: CGFloat = 1.0
        var sy: CGFloat = 1.0
        if viewAR > imageAR {
            sx = imageAR / viewAR
        } else if viewAR < imageAR {
            sy = viewAR / imageAR
        }
        let normX = screenX * sx + (1.0 - sx) / 2.0
        let normY = screenY * sy + (1.0 - sy) / 2.0
        return CGPoint(x: normX * size.width, y: normY * size.height)
    }
}
