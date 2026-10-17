# Technology Stack

_Last updated: 2026-10-17_

## Platform & Languages

- **Platform**: iOS / iPadOS 17.0 以上。SwiftUI アプリ（App エントリは `NekozeFixApp.swift`）。
- **Language**: Swift。型は値型（`struct` / `enum`）を優先し、参照型は所有とライフサイクルが必要な Services / Session に限定する。
- **外部依存なし**: Apple 純正フレームワークのみ。新規依存（サードパーティ含む）を追加しない。

## Frameworks

| 用途 | フレームワーク | 備考 |
|---|---|---|
| カメラ | AVFoundation | フロント／バック、VGA プリセット、`RotationCoordinator` による回転角 |
| 姿勢推定 | Vision | 顔・ボディポーズ（耳・肩）検出。推論はサンプルバッファキュー上で実行 |
| 傾き | CoreMotion | 重力取得。天方向基準の解決に使う |
| 音声 | AVFoundation | `AVAudioSession` playback カテゴリでマナーモード下も再生 |
| UI | SwiftUI | 画面は `SessionSnapshot` の公開状態を購読するのみ |
| テスト | XCTest | `@testable import NekozeFix` |

## Concurrency Model

並行性の規則は判定の正しさに直結するため厳守する。

- **単一書き込み点**: `PostureSessionManager` は `@MainActor`。セッション状態（`SessionSnapshot`）の唯一の書き込み点であり、UI は状態表示とコマンド送信のみ。
- **推論はバックグラウンドキュー**: Vision 推論はサンプルバッファ／検出キュー上で実行し、UI 更新のみメインキューへ hop する。
- **共有状態は明示的な排他で守る**: 検出キューと Main をまたぐ可変状態は `NSLock`（`withLock`）で保護する。例: `FrameThrottle`（`throttleLock`）、`MotionService` の `SharedState`（`@unchecked Sendable` + `NSLock`）、`LockedMainHopGate`。ロック・キュー・共有状態の関係は `.kiro/steering/concurrency-model.md` に図解する。
- **nonisolated アクセス**: 検出キューから直接読む必要のある値は `nonisolated(unsafe)` で公開し、参照の不変性またはロックで安全性を担保する。新たなロック階層を安易に増やさない。
- **新規スレッド機構を避ける**: タイマーやスレッドを新設するより、既存の直列キュー（例: `throttleResetQueue`）と配送則に乗せる。非同期の適用は `async` 配送で行い、判定中の変更を起こさない。
- **時計は単調時刻系に統一**: 経過時間・ゲート・しきい値判定には `CACurrentMediaTime` 系（`TimeInterval`）を使い、`Date`（暦時刻・壁時計）を使わない。

## Development Standards

- **コメントは日本語**: 既存コードに合わせ、意図・根拠・設計参照（design.md / ADR / CONTEXT.md）を日本語で記す。変更の背景は ADR に集約する。
- **数値パラメータは根拠を残す**: 閾値・頻度・ゲート秒数等の既定値は design.md の Grilling Decisions と ADR に定義し、コード変更時はドキュメントを同期する。
- **TDD**: 機能実装・バグ修正はテスト先行（red-green-refactor）を基本とする。Domain は純粋関数としてテストし、Services はシーム（プロトコル）越しにテストダブルを注入する。
- **回帰を必ず取る**: 間引き・頻度・hop 削減の変更では、3秒確定則・近側選択・代替鎖・通知仕様の不変を既存テストで確認する。
- **実機依存は明示**: 通知音のマナーモード再生、wake lock、消費電力などシミュレータで検証不能な挙動は、design.md の Testing Strategy に従い実機計測として扱う。
- **Xcode への登録必須**: 新しい `.swift`（ソース・テスト）は `NekozeFix.xcodeproj/project.pbxproj` に登録する（file reference + build phase）。ディスクに置くだけではビルドされない。

## Commands

```bash
# ビルド（接続済み実機を Destination にする。端末名は -showdestinations で確認）
xcodebuild -project NekozeFix.xcodeproj -scheme NekozeFix \
  -destination 'platform=iOS,name=<device-name>' build

# 実機へインストール（ビルド済みアプリを転送）
xcrun devicectl list devices
xcrun devicectl device install app --device <device-udid> \
  ~/Library/Developer/Xcode/DerivedData/NekozeFix-*/Build/Products/Debug-iphoneos/NekozeFix.app

# 全テスト（シミュレータ）
xcodebuild -project NekozeFix.xcodeproj -scheme NekozeFix \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# 単体テスト
xcodebuild ... test -only-testing:NekozeFixTests/<Suite>/<testMethod>
```
