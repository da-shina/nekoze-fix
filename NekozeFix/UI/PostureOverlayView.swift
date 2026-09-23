import SwiftUI
import AVFoundation

/// 姿勢検知のポイントとラインを可視化するオーバーレイ。
struct PostureOverlayView: View {
    enum Mode {
        case reference // 確定時の姿勢 (グレー)
        case current   // 現在の姿勢 (カラー)
    }

    let mode: Mode
    let referenceAngle: Double
    let currentPoints: [CGPoint]
    let nearSide: Side?
    /// 前面カメラ等でプレビューがミラー表示されているか。
    /// Vision 座標の x 反転と緑線方向の決定に使用。
    var isMirrored: Bool = true
    /// キャプチャ画像のアスペクト比（AspectFit 補正用）
    var imageAspectRatio: CGFloat = 4.0 / 3.0
    /// 現在のデバイス向き。Vision 座標はポートレート基準で出力されるため、
    /// プレビューの回転に合わせて座標変換する。
    var videoOrientation: AVCaptureVideoOrientation = .portrait

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                let isRef = mode == .reference
                let shoulderColor = isRef ? Color.gray.opacity(0.5) : Color.blue
                let earColor = isRef ? Color.gray.opacity(0.5) : Color.green
                let lineColor = isRef ? Color.gray.opacity(0.3) : Color.yellow

                // 肩のライン (両肩そろったときのみ)
                if currentPoints.count >= 2 && currentPoints[0] != .zero && currentPoints[1] != .zero {
                    Path { path in
                        let pL = normalizePoint(currentPoints[0], in: geometry.size)
                        let pR = normalizePoint(currentPoints[1], in: geometry.size)
                        path.move(to: pL)
                        path.addLine(to: pR)
                    }
                    .stroke(shoulderColor, lineWidth: 4)
                }

                // 肩のポイント (左右それぞれ、検出できた方だけ表示)
                ForEach(0..<2, id: \.self) { i in
                    if i < currentPoints.count && currentPoints[i] != .zero {
                        Circle()
                            .fill(shoulderColor)
                            .frame(width: 12, height: 12)
                            .position(normalizePoint(currentPoints[i], in: geometry.size))
                    }
                }

                // 耳のポイント (左右それぞれ、検出できた方だけ表示)
                ForEach(2..<4, id: \.self) { i in
                    if i < currentPoints.count && currentPoints[i] != .zero {
                        Circle()
                            .fill(earColor)
                            .frame(width: 12, height: 12)
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
                    .stroke(lineColor, lineWidth: 5)
                }

                // 基準となる直線（両モードで表示）
                if currentPoints.count >= 6 && currentPoints[0] != .zero && currentPoints[1] != .zero && currentPoints[4] != .zero && currentPoints[5] != .zero {
                    referenceArc(in: geometry.size, isReference: isRef)
                }
            }
        }
    }

    /// 基準線（緑またはグレー）と、黄（現在）〜緑／グレー（基準）のなす角を示す弧
    @ViewBuilder
    private func referenceArc(in size: CGSize, isReference: Bool) -> some View {
        let startPoint = normalizePoint(currentPoints[5], in: size)
        let length: CGFloat = 200

        // 両肩の画面座標から肩ラインベクトル (dx, dy) を算出（左から右への向き）
        let pL = normalizePoint(currentPoints[0], in: size)
        let pR = normalizePoint(currentPoints[1], in: size)
        let leftP = (pL.x <= pR.x) ? pL : pR
        let rightP = (pL.x <= pR.x) ? pR : pL
        let dx = rightP.x - leftP.x
        let dy = rightP.y - leftP.y
        let shoulderDist = hypot(dx, dy)

        // 肩ラインに対して直角かつ上向き (-y方向) の単位垂線ベクトル
        // (dx, dy) と (dy, -dx) の内積は dx*dy - dy*dx = 0 (直角)
        // dx >= 0 のため -dx <= 0 (画面上向き)
        let unitPerpX: CGFloat = shoulderDist > 0 ? (dy / shoulderDist) : 0.0
        let unitPerpY: CGFloat = shoulderDist > 0 ? (-dx / shoulderDist) : -1.0

        let end = CGPoint(
            x: startPoint.x + unitPerpX * length,
            y: startPoint.y + unitPerpY * length
        )
        let baselineColor: Color = isReference ? Color.gray : Color.green
        let baselineWidth: CGFloat = isReference ? 4.0 : 6.0
        Path { path in
            path.move(to: startPoint)
            path.addLine(to: end)
        }
        .stroke(baselineColor, lineWidth: baselineWidth)

        let pE = normalizePoint(currentPoints[4], in: size)
        let yellowAngle = atan2(pE.y - startPoint.y, pE.x - startPoint.x)
        let greenAngle = atan2(end.y - startPoint.y, end.x - startPoint.x)
        let delta = wrappedDelta(yellowAngle - greenAngle)
        let arcColor: Color = isReference ? Color.gray : Color.green
        let arcWidth: CGFloat = isReference ? 2.0 : 4.0
        Path { arc in
            arc.addArc(
                center: startPoint,
                radius: 80,
                startAngle: .radians(greenAngle),
                endAngle: .radians(yellowAngle),
                clockwise: delta < 0
            )
        }
        .stroke(arcColor, lineWidth: arcWidth)
    }

    /// 角度差を (-π, π] に正規化。符号が短距離回る方向を示す。
    /// truncatingRemainder は被除数の符号を保持するため、負の剰余を補正する。
    private func wrappedDelta(_ angle: CGFloat) -> CGFloat {
        let period = 2 * CGFloat.pi
        var normalized = (angle + .pi).truncatingRemainder(dividingBy: period)
        if normalized < 0 { normalized += period }
        normalized -= .pi
        return normalized == -.pi ? .pi : normalized
    }

    private func normalizePoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        // Vision 座標はポートレート基準 (0,0)左下、x右、y上
        // 画面座標は (0,0)左上、x右、y下
        // プレビューは videoOrientation に従って回転表示されるため、
        // オーバーレイも同じ回転を適用する
        let screenX: CGFloat
        let screenY: CGFloat
        switch videoOrientation {
        case .portrait, .portraitUpsideDown:
            screenX = point.x
            screenY = 1.0 - point.y
        case .landscapeRight:
            // ホームボタン右: ポートレート座標を90°右回転
            screenX = point.y
            screenY = 1.0 - point.x
        case .landscapeLeft:
            // ホームボタン左: ポートレート座標を90°左回転
            screenX = 1.0 - point.y
            screenY = point.x
        @unknown default:
            screenX = point.x
            screenY = 1.0 - point.y
        }

        // ランドスケープ時は画像の縦横が逆転するため AR も逆数にする
        let imageAR = videoOrientation.isLandscape ? 1.0 / imageAspectRatio : imageAspectRatio
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
