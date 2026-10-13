# Research: mainactor-throttle

## Summary

- **Feature**: `mainactor-throttle`
- **Discovery Scope**: Extension（既存の `captureOutput`→`processDetection` 受け渡し経路の拡張）
- **Key Findings**:
  - `captureOutput` は `detectionQueue`（直列）上の同期実行で、全フレーム `PoseDetector.detect` 後に `Task { @MainActor in ... }` を生成し `snapshot.videoAspectRatio` 更新と `processDetection` を毎フレーム実行する
  - 判定系の時間駆動性（`TimedConditionGate.tick` の `deltaTime` 駆動、`CalibrationLogic.ingest` の `now` 駆動、0.5秒系グレース）は間引き耐性があり、遷移強制と組み合わせれば判定継続性を保てる
  - 検出結果の3値（`pose`・`personOnly`・`absent`）は上流2 spec の出力契約であり、受け渡し削減は意味を変えずに配送頻度だけを制御できる

## Research Log

### 拡張点の特定（captureOutput 経路）

- **Context**: 毎フレームの Task 生成箇所と Main 渡し前段の計測点を特定する
- **Sources Consulted**: `NekozeFix/Session/PostureSessionManager.swift`（`captureOutput`、`processDetection`、`updateState`、`deliverRotationAngles`、`deviceFinalizedHandler`、`setupSettingsObservation`）、`NekozeFix/Services/CameraSessionManager.swift`（`detectionQueue` 定義・デリゲート設定）、`NekozeFix/Services/PoseDetector.swift`（`Detection` 3値）
- **Findings**:
  - フレーム毎 Task 生成は `captureOutput` の1箇所のみ。`deliverRotationAngles`・`deviceFinalizedHandler`・設定購読の Task は事象駆動（KVO・設定変更）であり毎フレーム発生しない
  - `captureOutput` は `detectionQueue`（`com.nekozefix.camera.detection`、直列）で呼ばれ、`detect` は同期実行、`alwaysDiscardsLateVideoFrames` が遅延破棄を担う
  - `processDetection` は `@MainActor` 上で信頼度記録・3値分岐・閾値フィルタ・ホールド・`PostureAnalyzer.analyze`・可視化点構築・EMA・`updateState`（デバウンス・校正投入／監視判定・ゲート・通知・ガイド）を毎フレーム実行する
  - `snapshot.videoAspectRatio` はバッファ実寸から毎フレーム算出・無条件書込みされる（不変値更新の回避余地）
- **Implications**: 集約点は `captureOutput` の Task 生成直前に置く。事象駆動の3箇所は洗い出し結果として変更対象外と明記する

### 上流出力契約（throttled inference output contract）

- **Context**: 処理順序「間引き→条件化→受け渡し削減」の最終段として、受け渡し削減が依拠できる入力契約を確認する
- **Sources Consulted**: `.kiro/specs/vision-fps-throttle/design.md`（間引き判定器・呼出統合・順序間引き→条件化）、`.kiro/specs/vision-face-conditional/design.md`（条件実行器・`detect` 公開署名・3値の意味）
- **Findings**:
  - `detect` の公開署名と3値の意味（姿勢あり・人物あり姿勢不明・人物不在）は両 spec で不変保証されている。受け渡し削減はこの契約を入力として消費するのみで変更しない
  - 上流の計測値（入力FPS・推論FPS、成功／失敗経路の回数・時間）は本 spec の受け渡し計測と区別される（対象が異なるため二重計数にならない）
  - fps-throttle の `FrameThrottle`（値型ゲート＋計数内包・検出キュー閉じ込め）は本 spec のゲート設計の前例となる
- **Implications**: 上流契約の変更（署名・3値意味・順序変更）は本 spec の再検証トリガとする。ゲートは値型＋計数内包の方針を踏襲する

### 判定系の時間駆動性と遷移の洗い出し

- **Context**: 受け渡し削減が判定継続性に波及しない分離点を見つける
- **Sources Consulted**: `NekozeFix/Domain/TimedConditionGate.swift`（`tick(isConditionMet:deltaTime:)`）、`NekozeFix/Domain/CalibrationLogic.swift`（`ingest(..., now:)`）、`PostureSessionManager.updateState`（0.5秒系デバウンス・肩欠測猶予・ホールド・即時改善・通知）
- **Findings**:
  - 確定ゲート・校正蓄積・人物不在デバウンス・肩欠測猶予・キーポイントホールドはいずれも時刻差分駆動であり、到着回数に依存しない。到着間隔が延びても `deltaTime`・`now` が間隙を吸収する
  - 判定転換に直結する事象は検出種別の遷移（`absent`・`personOnly` の出現／解消）と校正フェーズ中の蓄積であり、定常 `pose` 連続とは区別できる
  - 通知予算（確定→再生0.5秒以内）に対し、0.5秒系グレース（人物不在・肩欠測・ホールド）より十分小さい表示更新間隔であれば回帰余地は小さい
  - `MotionService.latestGravityInKeypointSpace` の読取りと `settingsStore` 閾値読取りは Main 側にあり、判定を検出キューへ移す分離は actor 境界をまたぐ大手術になる
- **Implications**: 判定処理自体は Main に残し、配送頻度の制御（定常間引き＋遷移強制＋フェーズ考慮）で hop を削減する。表示更新間隔は0.5秒系定数より十分小さく取り、通知遅延の実測で検証する

### actor 隔離と書込み経路

- **Context**: `@MainActor` 唯一書込み点の原則を維持したまま検出キュー側に判定状態を持つ設計にする
- **Sources Consulted**: `PostureSessionManager`（`@MainActor final class`、`nonisolated captureOutput`）、`NekozeFix/Types/PostureTypes.swift`（`SessionSnapshot` 値型、`setPhase` 唯一経路の慣例）、`CLAUDE.md` Architecture（Types → Domain → Services → Session → UI、`PostureSessionManager` が唯一の書込み点）
- **Findings**:
  - `snapshot` への書込みは `processDetection`・`updateState`・`setPhase` 経路に集約されており、この原則は維持する
  - ゲートの待機スロットは検出キュー（書込み）と Main（読取り・排出）の2スレッドから触れるため、単一スロット＋錠による最新優先の閉じ込めが必要
  - 判定ロジック（`PostureAnalyzer` 純関数）は変更対象外であり、表示専用値（`videoAspectRatio`・`keypointConfidences`・`earShoulderVector`・可視化点）の書込み最適化は判定に波及しない
- **Implications**: 新規状態は `MainHopGate` に閉じ込め、錠付き単一スロットで最新優先を実現する。`snapshot` 書込み経路の単一性は変えない

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| 検出キュー側ゲート＋単一スロット合流 | 検出キュー上で配送可否を判定し最新結果のみ単一スロット保持、Main 側で排出 | 新規スレッド機構なし、待機蓄積なし、判定は Main に残り actor 境界を保つ | 判定自体の Main 実行は残る（表示側削減が主効果） | 採用。FrameThrottle 前例と整合 |
| 判定の検出キュー移管 | `analyze`・ゲート・校正投入を検出キューで実行し表示のみ Main | hop 削減が最大 | snapshot・Motion・設定の actor 境界またぎ、状態二重化の divergence リスク | 不採用。分離コストが効果を上回る |
| Combine スロットル結線 | 発行側に throttle 演算子を追加 | 記述が短い | パイプライン変更・テスト困難・遷移強制の表現が弱い | 不採用 |

## Design Decisions

### Decision: 定常間引き＋遷移強制＋フェーズ考慮の三条件ゲート

- **Context**: 単純な受け渡し間引きではなく判定継続性を担保する必要がある
- **Alternatives Considered**:
  1. 等間隔の一律間引き — 実装は単純だが遷移フレームの遅延が判定に波及しうる
  2. 三条件ゲート（定常は表示更新間隔、遷移は即時配送、校正中は全量配送） — 判定転換の欠落を構造的に防ぐ
- **Selected Approach**: 2を採用。`pose` 定常連続のみ表示更新間隔で間引き、`absent`・`personOnly`・検出種別遷移は即時配送、`.calibrating` フェーズ中は全量配送する
- **Rationale**: 時間駆動の判定系と相性が良く、3秒確定・0.5秒系猶予・校正蓄積の意味を変えない
- **Trade-offs**: ゲート条件が3分岐になる代わりに判定非回帰の検証が容易になる
- **Follow-up**: 表示更新間隔の初期値の妥当性を通知遅延の実測で検証する

### Decision: ゲートと計測の一体化（FrameThrottle 踏襲）

- **Context**: 待ち時間・蓄積・配送頻度の計測点をゲート判定点に一致させる
- **Alternatives Considered**:
  1. 計測器の独立コンポーネント化 — 責務分離は明確だが判定点との二重管理になる
  2. ゲート内への計数内包（投入数・配送数・破棄数・待機時間の保持と複写読出し） — 判定点での取りこぼしなし
- **Selected Approach**: 2を採用。上流の `FrameThrottle`・`PoseDetector` 計測器と同一方針
- **Rationale**: 計測の有無で配送挙動が変わらないことの検証が容易
- **Trade-offs**: なし（永続化・外部送出なし）
- **Follow-up**: 計測形式の変更は下流 dim-mode-saving への再確認対象とする

### Decision: 不変値スキップの対象限定

- **Context**: `videoAspectRatio` 等の不変値更新回避を判定に波及させない
- **Alternatives Considered**:
  1. 全 snapshot 項目の差分比較 — 比較コストと誤差定義が項目ごとに必要
  2. 表示専用かつ変化が稀な項目（画面比率）に限定し微小差を無視する — 効果が明確で安全
- **Selected Approach**: 2を採用。画面比率は変化時のみ書込み、可視化点・信頼度・ガイドベクトルは配送削減自体で churn を抑える
- **Rationale**: 判定が参照する値（基準角・距離・近側・ゲート）には触れず、表示専用値のみを対象化する
- **Trade-offs**: 削減効果の主因は配送頻度削減であり、不変値スキップは補助効果と位置づける
- **Follow-up**: 実測で表示更新回数の削減を確認する

## Risks & Mitigations

- 表示更新間隔による通知遅延の上振れ — 間隔を0.5秒系定数より十分小さく取り、確定→再生の実測で検証する
- 定常間引き中の短時間の改善見逃し — 猶予・ホールドの0.5秒に対し間隔は十分小さく、遷移強制が人物不在系を即時配送するため影響は間隔内に収まる。実測で確認する
- 待機スロットの競合 — 単一スロット＋錠に閉じ込め、単体検証で最新優先と欠落なしを確認する
- 上流契約の変更 — 署名・3値意味・順序の変更を再検証トリガとして明記する

## References

- `.kiro/specs/vision-fps-throttle/design.md` — 間引き→条件化の順序と `FrameThrottle` 前例
- `.kiro/specs/vision-face-conditional/design.md` — 検出3値の出力契約
- `.kiro/specs/nekoze-fix/requirements.md` — §3.3 状態表示、§5 通知、NFR 8.2（0.5秒以内）、§8 ライフサイクル
- `NekozeFix/Session/PostureSessionManager.swift` — `captureOutput`・`processDetection`・`updateState` の現行実装
