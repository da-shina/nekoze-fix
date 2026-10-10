# Research: vision-fps-throttle

## Summary

- **Feature**: vision-fps-throttle
- **Discovery Scope**: Extension（既存の取得・推論パイプラインへの間引き追加）
- **Key Findings**:
  - 間引きの拡張点は `PostureSessionManager.captureOutput` 先頭に局在し、デバイス側の frameDuration 変更は不要である
  - 時刻源はサンプルバッファの presentation timestamp が適し、コールバック遅延の影響を受けない
  - 3秒確定ゲートと0.5秒系猶予は時刻差分基準のため、フレーム間引きで意味が変わらない

## Research Log

### 拡張点の特定

- **Context**: 間引きをどこに置くと入力FPSと推論FPSを独立制御できるかを特定する
- **Sources Consulted**: `NekozeFix/Session/PostureSessionManager.swift`（captureOutput、processDetection、slouchGate、猶予則）、`NekozeFix/Services/CameraSessionManager.swift`（sessionQueue、detectionQueue、alwaysDiscardsLateVideoFrames）、`.kiro/specs/vision-face-conditional/design.md`（検出契約と呼出点）
- **Findings**:
  - captureOutput は detectionQueue 上で同期的に `poseDetector.detect` を呼び、その後に MainActor へ hop して processDetection へ渡す
  - vision-face-conditional の条件化は `PoseDetector.detect` 内部に閉じるため、間引きは detect 呼出しの手前に置くと処理順序「間引き→条件化」が成立する
  - CameraSessionManager の入力経路（プリセット・解像度・alwaysDiscardsLateVideoFrames）は変更不要である
- **Implications**: 変更は Session 層の呼出点と新規の純粋ロジックに閉じ、依存方向 Types → Domain → Services → Session → UI を維持する

### 時刻源の選定

- **Context**: 間引き判定の基準をフレーム番号・到着時刻・提示時刻のどれにするかを選定する
- **Sources Consulted**: AVFoundation のサンプルバッファ時刻の既存利用、`PostureAnalyzer`・`TimedConditionGate` の時刻差分利用
- **Findings**:
  - フレーム番号基準は可変レートや破棄発生時に間隔が歪む
  - コールバック到着時刻は検出遅延の影響を受け、負荷時に判定がずれる
  - presentation timestamp はカメラ由来の単調な時刻であり、負荷の影響を受けない
- **Implications**: 間引き判定は presentation timestamp を基準とし、無効時刻の場合は推論実行側に倒す（検出欠落より電力消費を優先しない）

### 既存の時間基準則との整合

- **Context**: 間引きが3秒確定・0.5秒系ホールド・EMA平滑に与える影響を確認する
- **Sources Consulted**: `PostureSessionManager` の slouchGate（deltaTime 基準）、personMissing・shoulderMissing・keypointHold の猶予則、可視化 EMA
- **Findings**:
  - 確定ゲートと全猶予則は `CACurrentMediaTime` の差分で駆動し、フレーム到着回数に依存しない
  - EMA 平滑は到着点列に対する補間にすぎず、間引きで係数変更は不要である
  - 向き別信頼度閾値・近側選択・中央人物選択は Session・Analyzer 側の則であり、入力頻度に依存しない
- **Implications**: 判定系のロジック変更は不要であり、非回帰は既存テストと追加の間引きテストで検証する

### 計測と設定方法の選定

- **Context**: 入力FPS・推論FPSの計測配置と、推論FPS上限の設定方法を既存設計に合わせる
- **Sources Consulted**: `SettingsStore` の役割（永続化される利用者設定）、vision-face-conditional の錠付き計測器、roadmap の計測シナリオ
- **Findings**:
  - 推論FPS上限は利用者が操作する設定ではなく、実測比較で選定する調整定数であるため、永続化設定には入れない
  - 計測値は検証時の読み出し専用とし、永続化と外部送出は行わない（顔条件化の計測器と同一則）
  - 現状実測値・15FPS・10FPSの比較は検証活動として行い、結果を記録に残す
- **Implications**: 上限値は注入可能な設定として Session 側に置き、既定値の根拠は実測記録に結び付ける

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| デバイス frameDuration | カメラデバイスの最小・最大フレーム間隔で取得自体を制限する | AVFoundation 標準機能で実装が小さい | 入力FPSまで下がり独立制御にならない、15と10の比較が取得条件に依存する | 不採用 |
| コールバック時刻ゲート | captureOutput 先頭で時刻基準に破棄する | 入力と推論を独立制御できる、判定系に触れない | ゲート状態の初期化と計測の配置が必要である | 採用 |
| セマフォ latest-only | 推論中は新規受付を止め最新のみ残す | 滞留は防げる | 実行間隔が推論時間に従属し上限設定にならない | 不採用 |

## Design Decisions

### Decision: 間引き位置を captureOutput 先頭とする

- **Context**: 処理順序「間引き→条件化」を共有呼出点で保証する必要がある
- **Alternatives Considered**:
  1. デバイス frameDuration による取得制限
  2. captureOutput 先頭の時刻ゲートによる早期破棄
- **Selected Approach**: captureOutput 先頭で presentation timestamp を判定し、対象外を detect 呼出し前に破棄する
- **Rationale**: 条件化が detect 内部に閉じるため、手前での破棄が順序を保証する唯一の配置である
- **Trade-offs**: ゲート状態の所有が増える代わりに、入力経路と判定系への変更が不要になる
- **Follow-up**: 停止・再開時の初期化順序を実装時に検証する

### Decision: 時刻源に presentation timestamp を用いる

- **Context**: 負荷時に歪まない安定した間引き間隔が必要である
- **Alternatives Considered**:
  1. フレーム番号による等間隔選定
  2. コールバック到着時刻による間隔判定
  3. presentation timestamp による間隔判定
- **Selected Approach**: presentation timestamp を基準とし、無効時は推論実行側に倒す
- **Rationale**: カメラ由来の単調時刻であり、推論遅延や破棄発生の影響を受けない
- **Trade-offs**: 時刻取得が1行増える代わりに、レート変動下でも間隔が安定する
- **Follow-up**: 無効時刻の到達性をテストで確認する

### Decision: ゲート状態を検出キューに閉じ込める

- **Context**: 間引き判定状態の排他制御を最小の仕組みで実現する
- **Alternatives Considered**:
  1. 錠による保護
  2. 検出キューへの閉じ込めと計測読出しのみ錠保護
- **Selected Approach**: 判定状態は検出キュー上でのみ触り、検証用計測値の読出しだけを錠で保護する
- **Rationale**: captureOutput と detect が同一直列キューで同期実行されるため、判定経路に錠が不要である
- **Trade-offs**: 初期化要求は検出キューへ配送する必要がある
- **Follow-up**: MainActor 経路からの初期化順序をテストで確認する

### Decision: 純粋ロジックを新規小ファイルに分離する

- **Context**: 時刻ゲートの判定則をカメラなしで単体検証できるようにする
- **Alternatives Considered**:
  1. PostureSessionManager 内への直接実装
  2. 新規 FrameThrottle ファイルへの分離
- **Selected Approach**: 判定・計数・初期化を持つ値型を新規ファイルに置き、Session 側は結線のみ担う
- **Rationale**: 既存の Domain 純粋則の方針と整合し、境界が単体テストで直接検証できる
- **Trade-offs**: ファイルが1件増える代わりに、呼出点の変更が最小になる
- **Follow-up**: なし

### Decision: 上限値は注入可能な設定とし既定値の根拠を実測にする

- **Context**: 根拠なき固定値を禁止しつつ、検証で比較できる設定方法が必要である
- **Alternatives Considered**:
  1. SettingsStore への永続化設定
  2. Session 側の注入可能な上限値と実測に基づく既定値
- **Selected Approach**: 上限値を Session 側の注入可能な設定とし、既定値は現状・15・10 の実測比較で選定する
- **Rationale**: 推論FPS上限は利用者設定ではなく調整定数であり、永続化の対象外である
- **Trade-offs**: 検証活動が必須になる代わりに、固定値の恣意性を排除できる
- **Follow-up**: 計測シナリオの記録を検証時に残す

## Risks & Mitigations

- NFR 8.1（15fps以上構造）と10FPS制限の整合懸念 — 入力FPSと推論FPSの独立計測に基づき検証で確認し、推定記載しない
- 停止・再開時の初期化順序のずれ — 初期化を検出キューへ配送し、再開直後の過剰破棄がないことをテストする
- 無効時刻フレームの扱い — 推論実行側に倒し、検出欠落を起こさない
- 下流specへの波及（hop頻度・暗転時FPS） — 計測値の形式を安定させ、変更時は再検証する

## References

- AVFoundation サンプルバッファ時刻（`CMSampleBufferGetPresentationTimeStamp`）— 間引き判定の時刻源
- `.kiro/specs/vision-face-conditional/design.md` — 検出結果の3値契約と条件実行の呼出点
- `.kiro/specs/nekoze-fix/requirements.md` §4.2・NFR 8 — 3秒確定と15fps構造の制約
