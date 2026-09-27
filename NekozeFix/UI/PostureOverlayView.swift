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
    // Side 型のスコープエラーを回避するため削除 (body内で未使用)
    // let nearSide: Side?

    /// 前面カメラ等でプレビューがミラー表示されているか。
    var isMirrored: Bool = true
    /// キャプチャ画像のアスペクト比（バッファ実寸基準）
    var imageAspectRatio: CGFloat = 4.0 / 3.0
    /// 現在のビデオ向き。
    var videoOrientation: AVCaptureVideoOrientation = .portrait

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                let isRef = mode == .reference
                let shoulderColor = isRef ? Color.gray.opacity(0.5) : Color.blue
                let earColor = isRef ? Color.gray.opacity(0.5) : Color.green
                let lineColor = isRef ? Color.gray.opacity(0.3) : Color.yellow
                let guidelineColor = isRef ? Color.gray.opacity(0.6) : Color.green

                // 肩のライン
                if currentPoints.count >= 2 && currentPoints[0] != .zero && currentPoints[1] != .zero {
                    Path { path in
                        let pL = normalizePoint(currentPoints[0], in: geometry.size)
                        let pR = normalizePoint(currentPoints[1], in: geometry.size)
                        path.move(to: pL)
                        path.addLine(to: pR)
                    }
                    .stroke(shoulderColor, lineWidth: shoulderLineWidth)
                }

                // 肩のポイント
                ForEach(0..<2, id: \.self) { i in
                    if i < currentPoints.count && currentPoints[i] != .zero {
                        Circle()
                            .fill(shoulderColor)
                            .frame(width: pointSize, height: pointSize)
                            .position(normalizePoint(currentPoints[i], in: geometry.size))
                    }
                }

                // 耳のポイント
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
        let endPoint = calculateGuidelineEndPoint(startPoint: startPoint, size: size)

        Path { path in
            path.move(to: startPoint)
            path.addLine(to: endPoint)
        }
        .stroke(color, lineWidth: isReference ? guidelineLineWidthReference : guidelineLineWidthCurrent)
    }

    private func calculateGuidelineEndPoint(startPoint: CGPoint, size: CGSize) -> CGPoint {
        var vx = verticalVector.x
        var vy = verticalVector.y

        // 重力ベクトル (Vision座標系: y-up) を UI座標系 (y-down) に変換
        switch videoOrientation {
        case .portrait:
            vy = -vy
        case .portraitUpsideDown:
            vx = -vx
            // vy = vy // Removed self-assignment
        case .landscapeLeft:
            let tmp = vx
            vx = vy
            vy = -tmp
        case .landscapeRight:
            let tmp = vx
            vx = -vy
            vy = tmp
        @unknown default:
            break
        }

        let finalVX = isMirrored ? -vx : vx
        let finalVY = vy

        let viewAR = size.width / size.height
        let imageAR = imageAspectRatio
        let sx = viewAR > imageAR ? imageAR / viewAR : 1.0
        let sy = viewAR < imageAR ? viewAR / imageAR : 1.0

        let scaledVX = finalVX * sx * size.width
        let scaledVY = finalVY * sy * size.height

        let mag = hypot(scaledVX, scaledVY)
        let unitX = mag > 0 ? scaledVX / mag : 0
        let unitY = mag > 0 ? scaledVY / mag : 1

        return CGPoint(
            x: startPoint.x + unitX * guidelineLength,
            y: startPoint.y + unitY * guidelineLength
        )
    }

    /// 座標正規化関数
    private func normalizePoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        var screenX: CGFloat
        var screenY: CGFloat

        // 1. ビデオ向きに基づいた座標変換
        // Vision (左下原点, x-right, y-up) -> UI (左上原点, x-right, y-down)
        switch videoOrientation {
        case .portrait:
            screenX = point.x
            screenY = 1.0 - point.y
        case .portraitUpsideDown:
            screenX = 1.0 - point.x
            screenY = point.y
        case .landscapeLeft:
            screenX = point.y
            screenY = 1.0 - point.x
        case .landscapeRight:
            screenX = 1.0 - point.y
            screenY = point.x
        @unknown default:
            screenX = point.x
            screenY = 1.0 - point.y
        }

        // 2. ミラーリング対応
        // 前面カメラの場合、UI上の見た目を合わせるためX軸を反転させる
        let finalX = isMirrored ? 1.0 - screenX : screenX
        let finalY = screenY

        // 3. アスペクト比補正 (Aspect Fit 対応)
        let imageAR = imageAspectRatio
        let viewAR = size.width / size.height
        var sx: CGFloat = 1.0
        var sy: CGFloat = 1.0
        if viewAR > imageAR {
            sx = imageAR / viewAR
        } else if viewAR < imageAR {
            sy = viewAR / imageAR
        }

        let normX = finalX * sx + (1.0 - sx) / 2.0
        let normY = finalY * sy + (1.0 - sy) / 2.0
        return CGPoint(x: normX * size.width, y: normY * size.height)
    }
}
