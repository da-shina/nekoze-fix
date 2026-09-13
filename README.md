# NekozeFix

iPhone/iPad のフロント・バック両方のカメラで猫背をリアルタイム検知し、音で通知する iOS/iPadOS ネイティブアプリ。デスクに端末を置くだけで、姿勢の崩れを即座にフィードバックします。

- SwiftUI + Vision API のみ（サードパーティライブラリなし）
- カメラ映像・キーポイントはすべてデバイス内で処理（ネットワーク送出なし）
- 要 iOS/iPadOS 17.0 以上

## 使い方

1. アプリを起動し、カメラへのアクセスを許可
2. 正しい姿勢で 5 秒間キープしてキャリブレーション（基準姿勢を登録）
3. 監視開始。猫背が約 3 秒連続で確定すると通知音（うさぎ→かめ）でアラート

フロント・バック両カメラに対応し、正面設置・斜め 45 度設置のどちらも使用可能。ランドスケープ時のなで肩検出に対するガイダンスも表示されます。

## 主な機能


| 機能    | 説明                                                                                |
| ----- | --------------------------------------------------------------------------------- |
| 猫背検知  | 近側（画像上 x 座標が小さい側）の耳→肩ベクトルと垂直ベクトルのなす鋭角が、基準角度 + 閾値以上増加 → 3 秒連続で「確定猫背」→ 通知音          |
| 暗転モード | 画面を暗くして監視は継続。復帰時やタップ解除時に輝度と wake lock を復元                                         |
| 通知音   | AVAudioSession playback カテゴリでマナーモード下でも再生。デフォルト音はチップチューン「うさぎとかめ」（猫背継続中はループ長追従で再通知） |


## ビルド・テスト

```bash
# ビルド（接続済み実機を Destination にする。端末名は -showdestinations で確認）
xcodebuild -project NekozeFix.xcodeproj -scheme NekozeFix \
  -destination 'platform=iOS,name=<device-name>' build

# 全テスト（シミュレータ）
xcodebuild -project NekozeFix.xcodeproj -scheme NekozeFix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# 単体テスト実行例
xcodebuild ... test -only-testing:NekozeFixTests/PostureAnalyzerTests/testAngleCalculation_Acute0to90Degrees
```

## 音声クレジット

- 【8bit風】うさぎとかめ チップチューンアレンジBGM / カワモトンネルBMG（[https://booth.pm/ja/items/7388270）](https://booth.pm/ja/items/7388270）)  


