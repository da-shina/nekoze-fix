## Spec Report（再検証）

再検証日: 2026-11-08 / 対象: `main` (`d99ae7e`)

### 未実装 / 部分実装の要件

**Req 7.1, 7.2, 7.3 / Req 8.1, 8.2 — 条件別の実測記録** — AC 7.1: "通常モード・暗転モード・長時間人物不在・復帰直後・長時間監視の各条件で電力消費・復帰時間・検出精度を実測値として記録する"

- 通常モード・暗転モード: 電力の完全な実測あり（Energy Report ゲージ + Component Utilization）
- 長時間人物不在・復帰直後: CPU コンポーネントのみ（部分実装）
- 長時間監視: 電力未計測
- 復帰時間・検出精度: 5 条件すべて未計測
- `tasks.md` 4.2 は未完了（`[ ]`）。「IN PROGRESS」の明記はない

### 解消済み / 前提が更新された指摘

**Req 2.2 — 「更なる低下」は現行実装で成立** — AC 2.2: "画面暗転モードが継続し、かつ人物が長時間検出されない、the NekozeFix shall 推論実行頻度を暗転直後よりさらに低下させる"

- 旧根拠の `absent-vision-cost-4-2.md`（ウィンドウあたり Vision 時間 29% 増）は、顔フォールバック間引きの導入前の測定
- absent-vision-reduction（PR #27）で、長時間不在中の顔検出は 5 秒間隔に制限された
  - `NekozeFix/Services/PoseDetector.swift:138` — `evaluateFaceFallbackGate`
  - `NekozeFix/Session/ProlongedAbsenceTracker.swift:81` — `shouldExecuteAndRecordFaceFallback`
- 現行は「姿勢推論 10fps + 顔検出 最大 0.2fps」となり、暗転直後（不在フレームごとに顔検出）より実効 Vision 実行数は低い。ADR-0024 の「実効実行数」解釈で AC 2.2 を満たす
- FPS 上限は `.dimmed` / `.dimmedAbsent` とも 10.0（`NekozeFix/Session/PostureSessionManager.swift:495-500`）で意図どおり。5fps 化は ADR-0024 で却下済みであり、変更には ADR 改訂が必要
- 残る作業: 間引き後の Vision 負荷・電力を再実測した記録の取得

**Req 2.4 — 確定判定は 5 秒（実装は正しい／仕様文が古い）** — AC 2.4: "推論実行頻度を低下させている、the NekozeFix shall 3秒連続確定判定の意味を変更しない"

- ADR-0004 により確定判定は 3 秒から 5 秒へ変更済み。実装・README・CONTEXT は 5 秒で一致
- ゲートは推論回数ではなく経過時間（`TimedConditionGate`）ベースのため、推論頻度を下げても意味は変わらない
- 古いのは `dim-mode-saving/requirements.md:28` の「3秒」表記のみ。仕様文の更新が必要

### スコープクリープ判定の訂正

- **校正の一時停止/再開（コミット a3014ee）** — `main` 上の別機能。dim-mode-saving の成果物ではない
- **ステアリング一式（コミット 7cb1ad6）** — プロジェクト基盤の文書。機能スコープ外
- **`startFreqCycleIfEnabled()`** — 現行 `main` に存在しない（古い情報）
- **ADR-0024 / ADR-0025** — 仕様本文から参照されている正当な設計成果物（`requirements.md:67`、`design.md:422,429`）。スコープクリープではない

### サマリー

調査結果は「実測ギャップ 1 件（Req 7/8）」と「文書整合 1 件（Req 2.4）」に整理される。Req 2.2 は未達ではなく、absent-vision-reduction の顔フォールバック間引きにより実装済み。

優先対応:

1. `tasks.md` 4.2 の実測完了（復帰時間・検出精度・長時間監視、および間引き後の Vision 負荷・電力）
2. `dim-mode-saving/requirements.md` の「3秒」を「5秒」へ更新
3. 実測完了後に本レポートを更新
