import SwiftUI

/// 姿勢検知のポイントとラインを可視化するオーバーレイ。
struct PostureOverlayView: View {
    enum Mode {
        case reference // 確定時の姿勢 (グレー)
        case current   // 現在の姿勢 (カラー)
    }

    let mode: Mode
    let currentPoints: [CGPoint]
    let nearSide: Side?
    /// キャプチャ画像のアスペクト比（AspectFit 補正用）
    var imageAspectRatio: CGFloat = 4.0 / 3.0
    /// 判定と同一の基準線ベクトル（バッファ座標系、y上向き。analyze 済みで
    /// capture角θの(θ−90°)回転が適用されている）。
    /// Session が `analyze` の返値をそのまま受渡しする（単一解決）。
    /// 肩点起点に描画し、代替時も色・太さを変えない（無区別原則）。
    /// プレビューはダミー垂直 (0,1)。
    var referenceVector: CGVector = CGVector(dx: 0, dy: 1)

    // MARK: - 閾値ガイド表示パラメータ（スライダー操作中のみ）
    
    /// 角度閾値ガイドを表示するか
    var showAngleGuide: Bool = false
    /// 角度閾値（度）。基準角度 ± この値の位置に破線緑弧を描画
    var angleThresholdDegrees: Double = 0
    
    /// 距離閾値ガイドを表示するか
    var showDistanceGuide: Bool = false
    /// 基準距離（正規化座標系 0-1）。校正時の平均耳肩距離
    var referenceDistance: Double = 0
    /// 距離閾値（%）。基準距離のこの%以上で猫背判定
    var slouchDistanceThresholdPercent: Double = 0
    /// 近側耳→肩ベクトル（Vision正規化座標系、正規化済み）。ガイド線の方向決定に使用
    var earShoulderVector: CGVector = .zero

    // MARK: - ガイドアンカー用（キャリブレーション基準点）
    
    /// キャリブレーションで確定した基準点（グレー基準線のアンカー用）。
    /// referencePoints[5] = 近側肩、referencePoints[4] = 近側耳
    var referencePointsForGuide: [CGPoint] = []

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
                    
                    // 角度閾値ガイド弧（破線緑、半径 80pt、同中心・同半径）
                    if showAngleGuide {
                        angleThresholdGuideArc(in: geometry.size, isReference: isRef)
                    }
                    
                    // 距離閾値ガイド線（破線黄色、耳肩ベクトルに垂直）
                    if showDistanceGuide {
                        distanceThresholdGuideLines(in: geometry.size)
                    }
                }
            }
        }
    }

    /// ガイド用の基準点（キャリブレーション基準点）を取得する。
    /// referencePointsForGuide があればそれを使い、なければ currentPoints をフォールバックとする。
    private var guideAnchorPoints: [CGPoint] {
        if referencePointsForGuide.count >= 6 {
            return referencePointsForGuide
        }
        return currentPoints
    }

    /// キャリブレーション時の耳肩ベクトル（正規化済み、画面座標系）を取得する。
    /// これがガイド弧の中心方向（ゼロ偏差基準）になる。
    private func calibrationEarShoulderVector(in size: CGSize) -> (unitX: CGFloat, unitY: CGFloat, angle: CGFloat) {
        let anchorPoints = guideAnchorPoints
        let shoulderPoint = normalizePoint(anchorPoints[5], in: size)
        let earPoint = normalizePoint(anchorPoints[4], in: size)
        
        let dx = earPoint.x - shoulderPoint.x
        let dy = earPoint.y - shoulderPoint.y
        let len = hypot(dx, dy)
        
        if len > 0 {
            let ux = dx / len
            let uy = dy / len
            let angle = atan2(uy, ux)
            return (ux, uy, angle)
        }
        // フォールバック: referenceVector 方向
        let (sx, sy) = aspectFitScales(for: size)
        let rawDX = referenceVector.dx * sx * size.width
        let rawDY = -referenceVector.dy * sy * size.height
        let rawLen = hypot(rawDX, rawDY)
        let ux = rawLen > 0 ? rawDX / rawLen : 0.0
        let uy = rawLen > 0 ? rawDY / rawLen : -1.0
        return (ux, uy, atan2(uy, ux))
    }

    /// 基準ベクトルを画面座標系の単位ベクトルと基準角度に変換する共通処理。
    /// referenceArc で使用（判定基準線＝referenceVector方向）。
    private func resolveReferenceVector(in size: CGSize) -> (startPoint: CGPoint, greenAngle: CGFloat, unitX: CGFloat, unitY: CGFloat) {
        let startPoint = normalizePoint(currentPoints[5], in: size)
        let (sx, sy) = aspectFitScales(for: size)
        let rawDX = referenceVector.dx * sx * size.width
        let rawDY = -referenceVector.dy * sy * size.height
        let rawLen = hypot(rawDX, rawDY)
        let unitX: CGFloat = rawLen > 0 ? rawDX / rawLen : 0.0
        let unitY: CGFloat = rawLen > 0 ? rawDY / rawLen : -1.0

        let end = CGPoint(
            x: startPoint.x + unitX * 200,
            y: startPoint.y + unitY * 200
        )
        let greenAngle = atan2(end.y - startPoint.y, end.x - startPoint.x)
        return (startPoint, greenAngle, unitX, unitY)
    }

    /// 基準線（緑またはグレー）と、黄（現在）〜緑／グレー（基準）のなす角を示す弧。
    /// 方向は判定と同一の `referenceVector`（Vision座標系、y上向き）を使用し、
    /// 点列と同一の AspectFit 補正係数で画面座標系へ変換する。代替時も見た目は不変。
    @ViewBuilder
    private func referenceArc(in size: CGSize, isReference: Bool) -> some View {
        let (startPoint, greenAngle, _, _) = resolveReferenceVector(in: size)
        let length: CGFloat = 200
        let (_, _, unitX, unitY) = resolveReferenceVector(in: size)

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

    /// 角度閾値ガイド弧（破線緑、半径 80pt、基準弧と同中心・同半径）。
    /// **キャリブレーション時の耳肩ライン（ゼロ偏差基準）に対して** ± 角度閾値の位置に上下限ガイドを描画する。
    @ViewBuilder
    private func angleThresholdGuideArc(in size: CGSize, isReference: Bool) -> some View {
        let anchorPoints = guideAnchorPoints
        let startPoint = normalizePoint(anchorPoints[5], in: size)
        let (_, _, centerAngle) = calibrationEarShoulderVector(in: size)
        let guideColor: Color = isReference ? Color.gray : Color.green
        let guideWidth: CGFloat = isReference ? 2.0 : 4.0
        
        let thresholdRadians = angleThresholdDegrees * .pi / 180.0
        let upperAngle = centerAngle + thresholdRadians
        let lowerAngle = centerAngle - thresholdRadians

        Group {
            Path { arc in
                arc.addArc(
                    center: startPoint,
                    radius: 80,
                    startAngle: .radians(centerAngle),
                    endAngle: .radians(upperAngle),
                    clockwise: false
                )
            }
            .stroke(style: StrokeStyle(lineWidth: guideWidth, dash: [8, 4]))
            .foregroundColor(guideColor)

            Path { arc in
                arc.addArc(
                    center: startPoint,
                    radius: 80,
                    startAngle: .radians(lowerAngle),
                    endAngle: .radians(centerAngle),
                    clockwise: false
                )
            }
            .stroke(style: StrokeStyle(lineWidth: guideWidth, dash: [8, 4]))
            .foregroundColor(guideColor)
        }
    }

    /// 距離閾値ガイド線（破線黄色、耳肩ベクトルに垂直）。
    /// **グレーのキャリブレーション基準耳肩ベクトル `v` に垂直な破線黄色線**。
    /// キャリブレーション基準肩点 `pS` から `v` 方向に `baselineDist ± thresholdDist` 進んだ点を通る `v⊥` 方向の線分（長さ 80pt 程度）を描画する。
    @ViewBuilder
    private func distanceThresholdGuideLines(in size: CGSize) -> some View {
        let startPoint = normalizePoint(guideAnchorPoints[5], in: size)
        let guideWidth: CGFloat = 2.0
        let lineLength: CGFloat = 80

        if earShoulderVector.dx != 0 || earShoulderVector.dy != 0 {
            let (sx, sy) = aspectFitScales(for: size)
            let vecX = earShoulderVector.dx * sx * size.width
            let vecY = -earShoulderVector.dy * sy * size.height
            let vecLen = hypot(vecX, vecY)
            
            if vecLen > 0 {
                let unitX = vecX / vecLen
                let unitY = vecY / vecLen
                
                let perpX = -unitY
                let perpY = unitX

                // referenceDistance (正規化 0-1) を AspectFit 補正で画面ピクセルに変換
                let screenShortSide = min(size.width, size.height)
                let baselineDistance = referenceDistance * screenShortSide * sx
                let distanceThresholdPixels = baselineDistance * slouchDistanceThresholdPercent / 100.0

                let upperDist = baselineDistance + distanceThresholdPixels
                let lowerDist = baselineDistance - distanceThresholdPixels
                
                let upperCenter = CGPoint(
                    x: startPoint.x + unitX * upperDist,
                    y: startPoint.y + unitY * upperDist
                )
                let lowerCenter = CGPoint(
                    x: startPoint.x + unitX * lowerDist,
                    y: startPoint.y + unitY * lowerDist
                )

                Group {
                    Path { line in
                        line.move(to: CGPoint(x: upperCenter.x - perpX * lineLength / 2, y: upperCenter.y - perpY * lineLength / 2))
                        line.addLine(to: CGPoint(x: upperCenter.x + perpX * lineLength / 2, y: upperCenter.y + perpY * lineLength / 2))
                    }
                    .stroke(style: StrokeStyle(lineWidth: guideWidth, dash: [8, 4]))
                    .foregroundColor(.yellow)

                    Path { line in
                        line.move(to: CGPoint(x: lowerCenter.x - perpX * lineLength / 2, y: lowerCenter.y - perpY * lineLength / 2))
                        line.addLine(to: CGPoint(x: lowerCenter.x + perpX * lineLength / 2, y: lowerCenter.y + perpY * lineLength / 2))
                    }
                    .stroke(style: StrokeStyle(lineWidth: guideWidth, dash: [8, 4]))
                    .foregroundColor(.yellow)
                }
            }
        }
    }

    /// 角度差を (-π, π] に正規化。符号が短距離回る方向を示す。
    private func wrappedDelta(_ angle: CGFloat) -> CGFloat {
        let r = angle.remainder(dividingBy: 2 * .pi)
        return r == -.pi ? .pi : r
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
