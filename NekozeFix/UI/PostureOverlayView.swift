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
    /// Session が referenceSide 基準で生成する（未校正時は nearSide フォールバック）。
    var earShoulderVector: CGVector = .zero

    // MARK: - ガイドアンカー用（キャリブレーション基準点）

    /// キャリブレーションで確定した基準点（グレー基準線のアンカー用）。
    /// referencePoints[5] = 校正時近側肩（= referenceSide 肩）、referencePoints[4] = 校正時近側耳
    /// 起点は referenceSide 肩を使用し、方向・距離も同一側にそろえる。
    var referencePointsForGuide: [CGPoint] = []

    // MARK: - テスト可能な幾何計算（製品ロジック）

    /// 角度ガイドの上限・下限角を返す。
    static func angleGuideAngles(centerAngle: CGFloat, thresholdDegrees: Double) -> (upper: CGFloat, lower: CGFloat) {
        let thresholdRadians = CGFloat(thresholdDegrees * .pi / 180.0)
        return (centerAngle + thresholdRadians, centerAngle - thresholdRadians)
    }

    /// AspectFit 補正係数（製品ロジック）。
    static func aspectFitScales(imageAR: CGFloat, viewAR: CGFloat) -> (sx: CGFloat, sy: CGFloat) {
        if viewAR > imageAR {
            return (imageAR / viewAR, 1.0)
        } else if viewAR < imageAR {
            return (1.0, viewAR / imageAR)
        }
        return (1.0, 1.0)
    }

    /// 耳肩単位ベクトル（Vision正規化座標系）の画面上の1単位あたりピクセル長。
    /// x と y でスケールが異なるため、ベクトル向きに応じた hypot で換算する。
    static func screenPerUnit(earShoulderVector: CGVector, sx: CGFloat, sy: CGFloat, size: CGSize) -> CGFloat {
        hypot(earShoulderVector.dx * sx * size.width, earShoulderVector.dy * sy * size.height)
    }

    /// 基準距離（正規化 0-1）を画面ピクセルに換算する。
    static func baselineDistancePixels(referenceDistance: Double, earShoulderVector: CGVector, sx: CGFloat, sy: CGFloat, size: CGSize) -> CGFloat {
        CGFloat(referenceDistance) * screenPerUnit(earShoulderVector: earShoulderVector, sx: sx, sy: sy, size: size)
    }

    /// 距離ガイドの上限距離（猫背判定境界）を返す。要件 4.1: baseline × (1 + threshold/100) 以上で猫背。
    /// 下限は判定に使用しないためガイドも表示しない。
    static func upperDistance(baselineDistance: CGFloat, thresholdPercent: Double) -> CGFloat {
        baselineDistance * (1 + CGFloat(thresholdPercent / 100.0))
    }

    /// 距離閾値ドットの位置を返す。肩起点から中心線（校正時耳肩方向）延長線上の上限距離の点。
    /// 耳より上部（耳の外側）に配置される。
    static func distanceThresholdPoint(startPoint: CGPoint, centerAngle: CGFloat, upperDistance: CGFloat) -> CGPoint {
        CGPoint(
            x: startPoint.x + cos(centerAngle) * upperDistance,
            y: startPoint.y + sin(centerAngle) * upperDistance
        )
    }

    /// 距離閾値の2ドット位置を返す。上限・下限の角度閾値レイ上の上限距離の点。
    /// いずれも耳より上部（耳の外側）に配置される。下限距離の点は返さない。
    static func distanceThresholdDots(startPoint: CGPoint, upperAngle: CGFloat, lowerAngle: CGFloat, upperDistance: CGFloat) -> (upper: CGPoint, lower: CGPoint) {
        (
            distanceThresholdPoint(startPoint: startPoint, centerAngle: upperAngle, upperDistance: upperDistance),
            distanceThresholdPoint(startPoint: startPoint, centerAngle: lowerAngle, upperDistance: upperDistance)
        )
    }

    /// 距離ガイドの上限・下限距離と閾値ピクセルを返す。要件 4.5: baseline × (1 ± threshold/100)。
    /// 下限は旧仕様の残滓であり、ガイド表示には使用しない（upperDistance を使用）。
    static func distanceGuideDistances(baselineDistance: CGFloat, thresholdPercent: Double) -> (upper: CGFloat, lower: CGFloat, thresholdPixels: CGFloat) {
        let thresholdPixels = baselineDistance * CGFloat(thresholdPercent / 100.0)
        return (baselineDistance + thresholdPixels, baselineDistance - thresholdPixels, thresholdPixels)
    }

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

                    // 閾値ガイド（角度・距離の同時表示）
                    // スライダー操作中のみ表示（操作終了後は非表示）
                    if showAngleGuide || showDistanceGuide {
                        thresholdGuide(in: geometry.size, isReference: isRef)
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
    private func calibrationEarShoulderVector(in size: CGSize) -> (unitX: CGFloat, unitY: CGFloat, angle: CGFloat, distance: CGFloat) {
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
            return (ux, uy, angle, len)
        }
        // フォールバック: referenceVector 方向
        let (sx, sy) = aspectFitScales(for: size)
        let rawDX = referenceVector.dx * sx * size.width
        let rawDY = -referenceVector.dy * sy * size.height
        let rawLen = hypot(rawDX, rawDY)
        let ux = rawLen > 0 ? rawDX / rawLen : 0.0
        let uy = rawLen > 0 ? rawDY / rawLen : -1.0
        return (ux, uy, atan2(uy, ux), 200)
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

/// 閾値ガイド（角度・距離の同時表示）。
    /// いずれかのスライダー操作中に以下をすべて表示する（外側の呼び出し元で可視性をゲート）。
    /// - キャリブレーション基準耳肩ラインから ±angleThreshold の2本の破線（グレー）
    /// - 上限・下限の角度閾値レイ上の上限距離に2ドット（グレー、耳より上部）と、それらを結ぶ破線の弧
    ///   猫背判定は上限超過（baseline × (1 + threshold/100) 以上）のみのため、下限距離のドット・弧は表示しない。
    @ViewBuilder
    private func thresholdGuide(in size: CGSize, isReference: Bool) -> some View {
        let anchorPoints = guideAnchorPoints
        // 起点は referenceSide 肩（校正時近側肩 = anchorPoints[5]）。
        let startPoint = normalizePoint(anchorPoints[5], in: size)
        let (_, _, centerAngle, measuredLen) = calibrationEarShoulderVector(in: size)
        let (sx, sy) = aspectFitScales(for: size)

        // 基準距離は referenceDistance（正規化）を校正アンカー向きの画面換算でピクセル化する。
        // アンカー（校正時点列）は monitoring 中固定のため baseline も固定される。
        // ライブ earShoulderVector は毎フレーム向きが変わり baseline が可変になるため換算には使わない
        // （認識ポイント・角度への副作用ではなくガイド表示の安定性の問題）。
        // x/y スケールが異なるため hypot で向き依存に換算する。未校正時は計測長にフォールバック。
        // アンカー欠損時のみライブベクトルをフォールバックに使う（表示のみ、判定には影響しない）。
        let stableUnit: CGVector = {
            guard anchorPoints.count >= 6 else { return earShoulderVector }
            let dx = anchorPoints[5].x - anchorPoints[4].x
            let dy = anchorPoints[5].y - anchorPoints[4].y
            let len = hypot(dx, dy)
            guard len > 0 else { return earShoulderVector }
            return CGVector(dx: dx / len, dy: dy / len)
        }()
        let convertedBaseline = Self.baselineDistancePixels(
            referenceDistance: referenceDistance,
            earShoulderVector: stableUnit,
            sx: sx, sy: sy, size: size
        )
        let baselineDistance: CGFloat = (referenceDistance > 0 && convertedBaseline > 0) ? convertedBaseline : measuredLen

        // すべてグレーで統一
        let dotRadius: CGFloat = 6.0

        // 上限距離（判定境界）。角度ガイド線の長さにも使う。
        let upperDist = Self.upperDistance(
            baselineDistance: baselineDistance,
            thresholdPercent: slouchDistanceThresholdPercent
        )

        // 線の長さ（上限距離まで伸ばす）
        let lineLength = upperDist + 20

        // 角度閾値角（距離ガイドの2ドット位置にも使う）
        let (upperAngle, lowerAngle) = Self.angleGuideAngles(centerAngle: centerAngle, thresholdDegrees: angleThresholdDegrees)

        // 角度ガイド: 2本の角度閾値線（グレー破線）
        Group {
            // 上限角度の線
            Path { line in
                line.move(to: startPoint)
                line.addLine(to: CGPoint(
                    x: startPoint.x + cos(upperAngle) * lineLength,
                    y: startPoint.y + sin(upperAngle) * lineLength
                ))
            }
            .stroke(style: StrokeStyle(lineWidth: 2.0, dash: [8, 4]))
            .foregroundColor(Color.gray)

            // 下限角度の線
            Path { line in
                line.move(to: startPoint)
                line.addLine(to: CGPoint(
                    x: startPoint.x + cos(lowerAngle) * lineLength,
                    y: startPoint.y + sin(lowerAngle) * lineLength
                ))
            }
            .stroke(style: StrokeStyle(lineWidth: 2.0, dash: [8, 4]))
            .foregroundColor(Color.gray)
        }

        // 距離ガイド: 上下の角度閾値レイ上の上限2ドット（耳より上部）とそれらを結ぶ弧。下限距離は表示しない。
        let (upperDot, lowerDot) = Self.distanceThresholdDots(
            startPoint: startPoint,
            upperAngle: upperAngle,
            lowerAngle: lowerAngle,
            upperDistance: upperDist
        )

        Group {
            Circle()
                .fill(Color.gray)
                .frame(width: dotRadius * 2, height: dotRadius * 2)
                .position(upperDot)

            Circle()
                .fill(Color.gray)
                .frame(width: dotRadius * 2, height: dotRadius * 2)
                .position(lowerDot)
        }

        Path { arc in
            arc.addArc(
                center: startPoint,
                radius: upperDist,
                startAngle: .radians(lowerAngle),
                endAngle: .radians(upperAngle),
                clockwise: wrappedDelta(upperAngle - lowerAngle) < 0
            )
        }
        .stroke(style: StrokeStyle(lineWidth: 2.0, dash: [6, 3]))
        .foregroundColor(Color.gray)
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
        Self.aspectFitScales(imageAR: imageAspectRatio, viewAR: size.width / size.height)
    }
}
