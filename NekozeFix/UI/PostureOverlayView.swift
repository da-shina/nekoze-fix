import SwiftUI

/// 姿勢検知のポイントとラインを可視化するオーバーレイ。
struct PostureOverlayView: View {
    enum Mode {
        case reference // 確定時の姿勢 (グレー)
        case current   // 現在の姿勢 (カラー)
    }

    let mode: Mode
    let referenceAngle: Double
    let currentPoints: [CGPoint]
    let threshold: Double
    let nearSide: Side?
    /// キャプチャ画像のアスペクト比（AspectFit 補正用）
    var imageAspectRatio: CGFloat = 4.0 / 3.0

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

                // 基準となる直線 (Reference モードでは非表示)
                if !isRef && currentPoints.count >= 6 && currentPoints[4] != .zero && currentPoints[5] != .zero {
                    referenceArc(in: geometry.size)
                }
            }
        }
    }

    /// 緑の基準線と、黄（現在）〜緑（基準）のなす角を示す弧
    @ViewBuilder
    private func referenceArc(in size: CGSize) -> some View {
        let startPoint = normalizePoint(currentPoints[5], in: size)
        let length: CGFloat = 200
        let radians = referenceAngle * .pi / 180.0
        let xDirection: CGFloat = (nearSide == .left) ? -1.0 : 1.0
        let end = CGPoint(
            x: startPoint.x + (xDirection * length * sin(radians)),
            y: startPoint.y - length * cos(radians)
        )
        Path { path in
            path.move(to: startPoint)
            path.addLine(to: end)
        }
        .stroke(Color.green, lineWidth: 6)

        let pE = normalizePoint(currentPoints[4], in: size)
        let yellowAngle = atan2(pE.y - startPoint.y, pE.x - startPoint.x)
        let greenAngle = atan2(end.y - startPoint.y, end.x - startPoint.x)
        let delta = wrappedDelta(yellowAngle - greenAngle)
        Path { arc in
            arc.addArc(
                center: startPoint,
                radius: 80,
                startAngle: .radians(greenAngle),
                endAngle: .radians(yellowAngle),
                clockwise: delta < 0
            )
        }
        .stroke(Color.green, lineWidth: 4)
    }

    /// 角度差を (-pi, pi] に正規化。符号が短距離回る方向を示す
    private func wrappedDelta(_ angle: CGFloat) -> CGFloat {
        ((angle + .pi).truncatingRemainder(dividingBy: 2 * .pi)) - .pi
    }

    private func normalizePoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let visionX = point.x
        let visionY = 1.0 - point.y
        let imageAR = imageAspectRatio
        let viewAR = size.width / size.height
        var sx: CGFloat = 1.0
        var sy: CGFloat = 1.0
        if viewAR > imageAR {
            // 画面が画像より横長 -> 左右に余白（ピラーボックス）、上下はぴったり
            sx = imageAR / viewAR
            sy = 1.0
        } else if viewAR < imageAR {
            // 画面が画像より縦長 -> 上下に余白（レターボックス）、左右はぴったり
            sx = 1.0
            sy = viewAR / imageAR
        }
        let normX = visionX * sx + (1.0 - sx) / 2.0
        let normY = visionY * sy + (1.0 - sy) / 2.0
        return CGPoint(x: normX * size.width, y: normY * size.height)
    }
}
