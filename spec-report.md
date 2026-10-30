## Spec Report

### 未実装 / 部分実装の要件

**Req 7.1, 7.2, 7.3 / Req 8.1, 8.2 — 条件別の実測記録** — AC 7.1: "通常モード・暗転モード・長時間人物不在・復帰直後・長時間監視の各条件で電力消費・復帰時間・検出精度を実測値として記録する" — 通常モードと暗転モードのみが電力の完全な実測（Energy Report ゲージ + Component Utilization）を持つ。長時間人物不在と復帰直後は CPU コンポーネントのみ（部分実装）。長時間監視は完全に未計測。復帰時間と精度は 5 条件すべて未計測。tasks.md は 4.2 を "IN PROGRESS" と明記。

**Req 2.2 — 暗転時の段階的推論頻度低下（更なる低下）** — AC 2.2: "画面暗転モードが継続し、かつ人物が長時間検出されない、the NekozeFix shall 推論実行頻度を暗転直後よりさらに低下させる" — 実装は `.dimmed` と `.dimmedAbsent` の両方で FPS 上限を 10.0 に設定（PostureSessionManager.swift:474-478）。設計は「長時間不在は上限据置きで更なる低下は実効実行数に委ねるため暗転と同値」と明記。しかし absent-vision-cost-4-2.md は、ワークロードとして Vision 時間がウィンドウあたり 29% 増加（フォールバック顔検出が各推論で実行）することを確認しており、実際には「更なる低下」は達成されていない。

### スコープクリープ（要求されていない項目）

**NekozeFix/UI/CalibrationView.swift:44-52, NekozeFix/Domain/CalibrationLogic.swift:47-56, NekozeFixTests/CalibrationLogicTests.swift:518-570** — 校正の一時停止/再開（タップ）（コミット a3014ee, 14e1d7a）。タイマー上のタップで校正カウントダウンの一時停止/再開を可能にし、取り消し線インジケータを表示する。dim-mode-saving 仕様とは全く関係なし。

**.kiro/steering/architecture-diagram.md, concurrency-model.md, product.md, roadmap.md, structure.md, tech.md** — ステアリングディレクトリ全体（コミット 7cb1ad6）。プロジェクトのインフラストラクチャ文書であり、dim-mode-saving 機能の作業ではない。仕様は既存ステアリングを参照するのみであり、新規作成を要求していない。

**NekozeFix/Session/PostureSessionManager.swift:993-1019** — `startFreqCycleIfEnabled()` 一時的な周期サイクルヘルパー（motion-frequency 仕様の 5.1 用）。`-measureFreqCycle` 起動引数でガード。テスト専用だが、dim-mode-saving のスコープ外。

**docs/adr/0024-dim-absent-effective-rate.md, docs/adr/0025-energy-impact-as-power-measurement.md** — 実装中に作成された補足的な ADR。仕様が要求する成果物ではない。

### 実装上の懸念（誤りの可能性）

**Req 2.2 — 「更なる低下」が実装と矛盾** — AC 2.2: "推論実行頻度を暗転直後よりさらに低下させる" — `dimStageFPSLimit` は `.dimmed` と `.dimmedAbsent` の両方で 10.0 を返す（PostureSessionManager.swift:474-478）。設計は FPS 上限を据置き（「上限据置き」）とし、より低い値を「実効実行数」に委ねると明記。しかし absent-vision-cost-4-2.md の実測では、推論あたりの Vision 時間が倍増（約 17ms → 約 34ms）し、ウィンドウあたりの Vision 合計時間が 29% 増加（不在フレームごとに必須の顔フォールバックによる）。「更なる低下」の要件は実際のワークロードで違反している。

**Req 2.4 — 3 秒確定の意味維持（実装は正しいが脆弱）** — AC 2.4: "推論実行頻度を低下させている、the NekozeFix shall 3 秒連続確定判定の意味を変更しない" — ゲートは推論回数ではなく経過時間（`TimedConditionGate` 経由の 3 秒）を使用するため、意味は維持されている。ただし 10 FPS では約 30 回の推論、15 FPS では約 45 回の推論を目にする。上流が将来ゲートを推論回数ベースに変更すれば、この挙動は暗黙に壊れる可能性がある。現在の実装は経過時間ベースで設計に合致する。

### サマリー

調査結果 計 6 件。最も重大な問題: **Req 2.2「更なる低下」が実際には達成されていない** — 長時間不在ステージでは FPS 上限が変わらず、顔フォールバックにより Vision ワークロードが実際に増加しており、欠席ステージの消費電力削減という仕様の核心目標と直接矛盾している。Req 7/8 の実測ギャップ（5 条件のうち 4 条件で完全な実測が不足）とあわせて、仕様の検証基盤は不完全である。
