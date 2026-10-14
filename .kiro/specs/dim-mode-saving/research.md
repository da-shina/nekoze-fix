# Research: dim-mode-saving

## Summary
- **Feature**: `dim-mode-saving`
- **Discovery Scope**: Extension（既存の暗転・推論間引き・Motion取得への統合拡張）
- **Key Findings**:
  - 暗転は `enterDimMode`／`exitDimMode` の輝度保存・復元と `isDimmed` フラグによる表示切替に閉じ、監視・判定・Motion稼働は継続する
  - 推論頻度低下の土台は vision-fps-throttle の時刻ゲート方式（`FrameThrottle`）が提供し、上限は注入時固定が現行不変条件である
  - センサー頻度低下の土台は motion-frequency の間隔設定方式（`MotionUpdateFrequency`・`setUpdateFrequency`）が提供し、起停一本化（`setMotionRotationRunning`）の契約は不変である
  - 自動スリープ抑止は監視中強制の不変条件であり、暗転解除操作とは無関係に維持される

## Research Log

### 既存の暗転実装
- **Context**: 暗転中の必要処理と不要処理を区分するため、現行の暗転経路を確認した
- **Sources Consulted**: `NekozeFix/Session/PostureSessionManager.swift`（暗転・ライフサイクル・起停）、`NekozeFix/Types/PostureTypes.swift`（`SessionSnapshot.isDimmed`）、`NekozeFix/UI/MonitorView.swift`（暗転切替UI）
- **Findings**:
  - `enterDimMode` は輝度保存→輝度 0.0→`isDimmed = true` のみ行い、wake lock・Motion・カメラには触れない
  - `exitDimMode` は輝度復元のみ行い、センサー稼働状態を変更しない
  - 監視開始・停止・背景遷移・復帰の各経路が `exitDimMode` を呼び、暗転は監視状態に従属して解除される
  - 人物不在の表示は既存要件（nekoze-fix §3.4）に存在し、検出結果から不在状態を取得できる
- **Implications**: 省電力段階の管理は暗転フラグと検出結果を入力とする Session 側の協調に閉じ、輝度制御自体の変更は不要である

### 上流の推論頻度低下方式
- **Context**: 暗転時推論頻度低下の前提方式を確認した
- **Sources Consulted**: `.kiro/specs/vision-fps-throttle/design.md`（間引き判定器・FPS計測器・呼出統合）
- **Findings**:
  - 間引き判定は提示時刻の間隔基準で行い、処理順序は間引き→条件化である
  - `FrameThrottle` の上限間隔は注入時に定まり判定中に変わらないことが現行不変条件である
  - 入力到達数・推論実行数・破棄数の計測器が区別計数を提供する
- **Implications**: 暗転・不在での上限切替には上限変更の受口が必要であり、上流不変条件の拡張として再検証対象になる

### 上流のセンサー頻度低下方式
- **Context**: 暗転時センサー頻度低下の前提方式を確認した
- **Sources Consulted**: `.kiro/specs/motion-frequency/design.md`（頻度設定・省略則・計測・起停）、`NekozeFix/Services/MotionService.swift`（現行の取得・保持）
- **Findings**:
  - 許可値は毎秒30回・15回・10回のみで既定は毎秒30回、許可外値は既定維持である
  - 暗転時の省電力モード切替方針は dim-mode-saving の所有であり、本方式側は頻度変更の受口提供に留まる
  - 起停一本化（`setMotionRotationRunning`）の契約は変更しないことが共有則である
- **Implications**: 暗転・不在での頻度切替は受口の利用に留まり、許可値・既定値・起停則の変更は行わない

### 自動スリープ抑止と輝度制御の分離
- **Context**: 表示・センサー・スリープ抑止の独立制御の前提を確認した
- **Sources Consulted**: `.kiro/specs/nekoze-fix/requirements.md` §8.3／§8.4、PostureSessionManager の wake lock 不変条件（`isIdleTimerDisabled == (phase == .monitoring)`）
- **Findings**:
  - 抑止範囲は監視中に限定され、暗転モード中でも継続し、解除操作と無関係である
  - 輝度制御は暗転フラグに従属し、wake lock は監視フェーズに従属する
- **Implications**: 両者は既に独立に従属先を持ち、本機能はこの分離を維持するのみで新規の抑止則を作らない

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| 段階状態の値型隔離 | 通常・暗転・長時間不在の段階と遷移判定を純粋値型に閉じる | カメラなしで単体検証できる、Session の既存則を変えない | 不在しきい値の選定が残る | 既存の `TimedConditionGate`・`CalibrationLogic` の配置方針と整合する |
| 上流方式の直接利用 | 推論・センサーの低下を上流の確定方式の受口経由で切替える | 独自の間引き機構を作らない、共有シームの重複所有を避ける | 上流未実装時は待機が必要 | ロードマップの依存順（vision-fps-throttle・motion-frequency→dim-mode-saving）と整合する |
| カメラ停止の採用 | 暗転中にカメラ取得自体を停止する | 削減効果は最大 | 復帰遅延・検出欠落の危険、監視継続の期待変更 | 影響評価の完了までは採用しない |

## Design Decisions

### Decision: 省電力段階を純粋値型として隔離する
- **Context**: 通常・暗転・長時間不在の遷移則を検証可能にし、Session の既存則と混ぜない必要がある
- **Alternatives Considered**:
  1. Session 内に分岐を直接追加する — 変更は最小だが遷移則の単体検証ができない
  2. 段階管理の値型を新設する — 遷移則をカメラなしで検証できる
- **Selected Approach**: 段階（通常・暗転・長時間不在）と遷移判定・復帰則を持つ値型を Session 層に新設し、Session は適用結線のみ担う
- **Rationale**: 既存の層構造と値型隔離の方針（判定器の前例）に沿い、遷移則の回帰を単体検査で維持できる
- **Trade-offs**: 新規ファイルが1件増える代わりに、Session の分岐複雑化を避けられる
- **Follow-up**: 不在しきい値の既定値妥当性を実測記録で見直す

### Decision: 上流方式を採用し独自の間引き機構を作らない
- **Context**: 推論・センサーの頻度低下は上流specの確定方式で実現できる
- **Alternatives Considered**:
  1. 独自の間引き・頻度機構を作る — 共有シームの二重所有になり順序保証が崩れる
  2. 上流の受口を利用する — 所有境界を守り処理順序（間引き→条件化）を維持できる
- **Selected Approach**: 推論は間引き判定器の上限切替、センサーは頻度設定の受口を利用し、本specは段階に応じた切替え指示のみ所有する
- **Rationale**: ロードマップの共有シーム方針（setMotionRotationRunning 起停一本化、間引き→条件化の順序）と整合する
- **Trade-offs**: 上流の実装完了が前提になる代わりに、重複実装と境界違反を避けられる
- **Follow-up**: 上流の契約変更時は本specの再検証トリガーとして扱う

### Decision: カメラ停止は本フェーズで実装しない
- **Context**: カメラ停止は削減効果が大きい反面、監視継続の期待変更と復帰遅延の危険がある
- **Alternatives Considered**:
  1. 暗転直後から停止する — 要件 5.1（評価完了前の停止禁止）に違反する
  2. 評価手順のみ定義し停止実装は見送る — 要件 5 を満たし回帰危険を避けられる
- **Selected Approach**: カメラ停止の実装は範囲外とし、評価観点（復帰時間・再開時の検出遅延・再開コスト）と記録形式のみ定義する
- **Rationale**: 利用者の期待する監視動作を説明なく変更しない制約を守る
- **Trade-offs**: 本フェーズの削減は推論・センサー頻度に留まる代わりに、安全性を確保できる
- **Follow-up**: 評価記録が揃った段階で採用可否を別途判断する

## Risks & Mitigations
- 上流の上限変更受口・頻度設定受口が未実装の場合 — 受口の実装完了を先行条件とし、未完了時は本specの実装に入らない
- 不在しきい値の既定値が実利用に合わない場合 — 既定値を仮置きし実測記録で見直す。再検証トリガーとして記録する
- 頻度低下による検出遅延の増加 — 3秒確定則の不変を回帰で確認し、通知遅延の実測を記録する
- 暗転復帰時の上限・頻度戻し忘れ — 復帰経路（解除操作・監視開始・復帰）を一本化し、戻し忘れを結合検証で確認する

## References
- `.kiro/specs/nekoze-fix/requirements.md` §6・§8.3／§8.4・NFR 9.2 — 暗転・スリープ抑止・消費電力の上流制約
- `.kiro/specs/vision-fps-throttle/design.md` — 暗転時推論頻度低下の前提方式
- `.kiro/specs/motion-frequency/design.md` — 暗転時センサー頻度低下の前提方式と `setMotionRotationRunning` 共有則
- `CLAUDE.md` Architecture — 層方向（Types → Domain → Services → Session → UI）と Session 唯一書込み点
