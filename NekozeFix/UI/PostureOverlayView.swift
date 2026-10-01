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
    let nearSide: Side?
    /// 前面カメラ等でプレビューがミラー表示されているか。
    /// Vision 座標の x 反転と緑線方向の決定に使用。
    var isMirrored: Bool = true
    /// キャプチャ画像のアスペクト比（AspectFit 補正用）
    var imageAspectRatio: CGFloat = 4.0 / 3.0
    /// 判定と同一の基準線ベクトル（バッファ座標系、y上向き。analyze 済みで
    /// capture角の−θ回転が適用されている）。
    /// Session が `analyze` の返値をそのまま受渡しする（単一解決）。
    /// 肩点起点に描画し、代替時も色・太さを変えない（無区別原則）。
    /// プレビューはダミー垂直 (0,1)。
    var referenceVector: CGVector = CGVector(dx: 0, dy: 1)

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

                // 基準となる直線（両モードで表示、近側肩点起点）
                if currentPoints.count >= 6 && currentPoints[4] != .zero && currentPoints[5] != .zero {
                    referenceArc(in: geometry.size, isReference: isRef)
                }
            }
        }
    }

    /// 基準線（緑またはグレー）と、黄（現在）〜緑／グレー（基準）のなす角を示す弧。
    /// 方向は判定と同一の `referenceVector`（Vision座標系、y上向き）を使用し、
    /// 点列と同一の AspectFit 補正係数で画面座標系へ変換する。代替時も見た目は不変。
    @ViewBuilder
    private func referenceArc(in size: CGSize, isReference: Bool) -> some View {
        let startPoint = normalizePoint(currentPoints[5], in: size)
        let length: CGFloat = 200

        // 点列と同一の補正係数（sx, sy）をベクトルに適用する。
        // Vision座標系（y上向き）→画面座標系（y下向き）のため y 符号を反転する。
        let (sx, sy) = aspectFitScales(for: size)
        let rawDX = referenceVector.dx * sx * size.width
        let rawDY = -referenceVector.dy * sy * size.height
        let rawLen = hypot(rawDX, rawDY)
        let unitX: CGFloat = rawLen > 0 ? rawDX / rawLen : 0.0
        let unitY: CGFloat = rawLen > 0 ? rawDY / rawLen : -1.0

        let end = CGPoint(
            x: startPoint.x + unitX * length,
            y: startPoint.y + unitY * length
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
        let visionX = point.x
        let visionY = 1.0 - point.y
        let (sx, sy) = aspectFitScales(for: size)
        let normX = visionX * sx + (1.0 - sx) / 2.0
        let normY = visionY * sy + (1.0 - sy) / 2.0
        return CGPoint(x: normX * size.width, y: normY * size.height)
    }

    /// 点列とベクトルで共有する AspectFit 補正係数（sx, sy）。
    /// normalizePoint と同一の分岐であり、両者のスケールを一致させる。
    private func aspectFitScales(for size: CGSize) -> (sx: CGFloat, sy: CGFloat) {
        let imageAR = imageAspectRatio
        let viewAR = size.width / size.height
        if viewAR > imageAR {
            // 画面が画像より横長 -> 左右に余白（ピラーボックス）、上下はぴったり
            return (imageAR / viewAR, 1.0)
        } else if viewAR < imageAR {
            // 画面が画像より縦長 -> 上下に余白（レターボックス）、左右はぴったり
            return (1.0, viewAR / imageAR)
        }
        return (1.0, 1.0)
    }
}
