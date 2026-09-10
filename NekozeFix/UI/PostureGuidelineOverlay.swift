import SwiftUI

/// ユーザーがカメラに対して正しい位置に配置されるよう誘導するオーバーレイ。
struct PostureGuidelineOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景を少し暗くしてガイドを強調
                Color.black.opacity(0.4)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    ZStack {
                        // 垂直の基準線
                        Rectangle()
                            .fill(Color.white.opacity(0.6))
                            .frame(width: 2, height: 300)

                        // 上下のポイント (耳・肩の目安)
                        VStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                            Spacer()
                            Circle()
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                        }
                        .frame(height: 300)
                    }
                    .foregroundColor(.white)

                    Text("この線に合わせてください")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .ignoresSafeArea()
    }
}

struct PostureGuidelineOverlay_Previews: PreviewProvider {
    static var previews: some View {
        PostureGuidelineOverlay()
    }
}
