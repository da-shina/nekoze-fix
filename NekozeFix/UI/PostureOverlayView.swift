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

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                let isRef = mode == .reference
                let shoulderColor = isRef ? Color.gray.opacity(0.5) : Color.blue
                let earColor = isRef ? Color.gray.opacity(0.5) : Color.green
                let lineColor = isRef ? Color.gray.opacity(0.3) : Color.yellow

                if currentPoints.count >= 2 && currentPoints[0] != .zero && currentPoints[1] != .zero {
                    // 肩のライン
                    Path { path in
                        let pL = normalizePoint(currentPoints[0], in: geometry.size)
                        let pR = normalizePoint(currentPoints[1], in: geometry.size)
                        path.move(to: pL)
                        path.addLine(to: pR)
                    }
                    .stroke(shoulderColor, lineWidth: isRef ? 1 : 2)

                    // 肩のポイント
                    ForEach(0..<2) { i in
                        Circle()
                            .fill(shoulderColor)
                            .frame(width: isRef ? 4 : 8, height: isRef ? 4 : 8)
                            .position(normalizePoint(currentPoints[i], in: geometry.size))
                    }
                }

                if currentPoints.count >= 4 && currentPoints[2] != .zero && currentPoints[3] != .zero {
                    // 両耳のポイント
                    ForEach(2..<4) { i in
                        Circle()
                            .fill(earColor)
                            .frame(width: isRef ? 4 : 8, height: isRef ? 4 : 8)
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
                    .stroke(lineColor, lineWidth: isRef ? 1 : 3)
                }

                // 基準となる直線 (Reference モードでは非表示)
                if !isRef && currentPoints.count >= 6 && currentPoints[5] != .zero {
                    Path { path in
                        let startPoint = normalizePoint(currentPoints[5], in: geometry.size)
                        let length: CGFloat = 200
                        let radians = referenceAngle * .pi / 180.0
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
    }

    private func normalizePoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let visionX = point.x
        let visionY = 1.0 - point.y
        let imageAR: CGFloat = 4.0 / 3.0
        let viewAR = size.width / size.height
        var sx: CGFloat = 1.0
        var sy: CGFloat = 1.0
        if viewAR > imageAR {
            sx = 1.0
            sy = viewAR / imageAR
        } else if viewAR < imageAR {
            sx = imageAR / viewAR
            sy = 1.0
        }
        let normX = visionX * sx + (1.0 - sx) / 2.0
        let normY = visionY * sy + (1.0 - sy) / 2.0
        return CGPoint(x: normX * size.width, y: normY * size.height)
    }
}
