# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

NekozeFix: iPhone/iPadフロントカメラで猫背をリアルタイム検知し音で通知するiOS/iPadOSネイティブアプリ（SwiftUI + Vision、サードパーティライブラリなし）。

## Commands

```bash
# ビルド（Macに接続されたiOS DeviceをDestinationにする。接続端末名は
# `xcodebuild -project NekozeFix.xcodeproj -scheme NekozeFix -showdestinations` で確認）
xcodebuild -project NekozeFix.xcodeproj -scheme NekozeFix -destination 'platform=iOS,name=<device-name>' build

# 全テスト実行
xcodebuild -project NekozeFix.xcodeproj -scheme NekozeFix -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# 単体テスト実行
xcodebuild -project NekozeFix.xcodeproj -scheme NekozeFix -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:NekozeFixTests/PostureAnalyzerTests/testAngleCalculation_Acute0to90Degrees
```

テストは XCTest（`@testable import NekozeFix`）。`NekozeFixPackage/` は Package.swift を含まないビルド名残ディレクトリなので触らない。

## Architecture

依存方向は一方向に固定。左の層は右の層を知らない：

```
Types → Domain → Services → Session → UI
```

- **Types** (`NekozeFix/Types/PostureTypes.swift`): 全層共有の値オブジェクト・列挙（`SessionPhase`、`SessionSnapshot` など）
- **Domain** (`NekozeFix/Domain/`): 純関数のみ。I/O 禁止（`PostureAnalyzer` 角度計算・近側選択、`TimedConditionGate` 連続条件、`CalibrationLogic`）
- **Services** (`NekozeFix/Services/`): カメラ/Vision/音声/端末向き（`CameraSessionManager`、`PoseDetector`、`AlertPlayer`、`DeviceOrientationMonitor`）
- **Session** (`NekozeFix/Session/`): `PostureSessionManager` がセッション状態の**唯一の書き込み点**。UI は状態表示とコマンド送信のみ
- **UI** (`NekozeFix/UI/`): SwiftUI 画面。`SessionSnapshot` の公開状態だけを購読する

判定の核心: 近側（画像上 x 座標が小さい側）の耳→肩ベクトルと垂直ベクトルのなす鋭角が、キャリブレーション基準角度 + 閾値以上増加 → 3秒連続で「確定猫背」→ 通知音。暗転モードは独立サービスではなく `SessionSnapshot.isDimmed` フラグに対する UI 表現（監視・判定は継続）。

## Specification-Driven 開発（Kiro）

- 仕様: `.kiro/specs/nekoze-fix/`（spec.json / requirements.md / design.md / tasks.md / research.md / brief.md、language: ja）
- 設計判断の根拠: `design.md` の **Grilling Decisions（Q1〜Q24）** 表と `docs/adr/0001〜0013`。閾値デフォルト、ゲート秒数、再通知間隔、プリセット等の数値パラメータはここに定義されている
- ドメイン用語は `CONTEXT.md` の用語定義に厳密に従う（「猫背」「近側キーポイント」「確定猫背判定」等。Avoid 表記の類似語を使わない）
- コード挙動やパラメータを変えたら design.md / ADR / CONTEXT.md も同期する（git 履歴に docs sync の慣例あり）
- ワークフローはグローバル CLAUDE.md の通り: `/kiro-spec-*` → `/kiro-impl` → `/kiro-validate-*`。Markdown コンテンツは spec の language（ja）で書く

## 注意事項

- Vision 推論はサンプルバッファキュー上で実行し、UI 更新のみメインキューへ。`PostureSessionManager` は `@MainActor`
- 基準姿勢はプロセス内メモリのみ（永続化しない）
- カメラ映像・キーポイントはデバイス内処理のみ、ネットワーク送出禁止
- 実機依存の挙動（通知音のマナーモード再生、wake lock、消費電力）はシミュレータで検証不可 — design.md の Testing Strategy 参照

