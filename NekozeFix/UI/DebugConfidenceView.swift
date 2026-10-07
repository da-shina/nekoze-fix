import SwiftUI

/// DEBUG 用: 4点の生信頼度 [左耳, 右耳, 左肩, 右肩] を左上に表示する。
/// 校正・監視の両画面に overlay する。Release では EmptyView
///（見た目・レイアウトへの影響なし）。

struct DebugConfidenceView: View {
    /// 検証時のみ true にして使う。恒常表示はしない（削除せず無効化で残す）。
    static var isEnabled = false

    var confidences: [Double?] = []

    var body: some View {
        #if DEBUG
        if Self.isEnabled {
            Text(displayText)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white)
                .padding(6)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
        }
        #endif
    }

    #if DEBUG
    private var displayText: String {
        let padded = confidences + [nil, nil, nil, nil]
        func f(_ value: Double?) -> String {
            value.map { String(format: "%.2f", $0) } ?? "--"
        }
        return "耳L \(f(padded[0])) 耳R \(f(padded[1])) 肩L \(f(padded[2])) 肩R \(f(padded[3]))"
    }
    #endif
}

// MARK: - プレビュー

#Preview {
    DebugConfidenceView(confidences: [0.82, nil, 0.31, 0.12])
}
