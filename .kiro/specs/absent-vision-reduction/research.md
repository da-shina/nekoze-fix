# ギャップ分析: absent-vision-reduction

## 概要
- **機能**: `absent-vision-reduction` (P2・提案)
- **タイプ**: ブラウンフィールド拡張 — 既存の `vision-face-conditional`、`dim-mode-saving`、`vision-fps-throttle`、`mainactor-throttle`、`motion-frequency` と統合
- **主要課題**: 「長時間不在」を暗転モード専用からモード非依存に一般化し、長時間不在中の `PoseDetector` で顔フォールバックを間引くこと。ADR-0021 の「顔のみ＝人物あり」という意味は保持する。

---

## 1. 現状調査

### 主要アセットとアーキテクチャパターン

| レイヤ | コンポーネント | 役割 | 関連度 |
|--------|----------------|------|--------|
| Services | `PoseDetector` | Body pose + **顔フォールバック** (ADR-0021)。姿勢失敗時に **毎回** 顔検出を実行 | **主改修対象** — 長時間不在中に顔フェーズを間引く必要 |
| Session | `PostureSessionManager` | 単一ライター (`@MainActor`)。カメラ、検出、電力段階、計測を統括 | **統合点** — 長時間不在状態を管理し `PoseDetector` に伝達 |
| Session | `DimPowerPolicy` | 純粋値型。電力段階 (`normal` / `dimmed` / `dimmedAbsent`)、不在しきい値 (既定 60s)、遷移を所有 | **拡張対象** — 現在は暗転モードのみ。不在計測を一般化する必要 |
| Session | `FrameThrottle` | 時間間隔推論ゲート (通常 15fps / 暗転 10fps)。`setLimit(_:)` 受口 | 再利用 — **変更なし** (要件 2.3: 推論 FPS 上限不変) |
| Services | `MotionService` | 重力取得頻度 (30/15/10 Hz)。`setUpdateFrequency(_:)` 受口 | 再利用 — **変更なし** |

### 規約
- **レイヤリング**: Types → Domain → Services → Session → UI (厳格な一方向)
- **並行性**: 検出は `detectionQueue` (直列)、`MainActor` ホップは `LockedMainHopGate`、共有状態は `NSLock` で保護 (`throttleLock`, `SharedState.lock`)
- **テスト**: Domain 純粋関数を単体テスト、Services はプロトコルシーム経由、Session は `@testable` で結合テスト
- **計測**: 5秒窓ログ `[NekozeFix Metrics]` (到達、推論、破棄、推論時間、Motion サンプル)。電力は Xcode Energy Report (ADR-0025)

### 統合インターフェース
- `PoseDetector.detect(sampleBuffer:orientation:)` → `captureOutput` から `detectionQueue` 上で呼出し
- `PostureSessionManager.updateState(presence:...)` → `dimPowerPolicy.tick(isPersonDetected:now:)` を MainActor で呼出し
- `DimPowerPolicy.tick()` が新 `DimPowerStage` を返す → `applyDimPowerStage()` が FPS 上限 + Motion 頻度を調整

---

## 2. 要件実現可能性分析

### EARS 要件からの技術的必要事項

| 要件 | 必要事項 | 現状 | ギャップ |
|------|----------|------|--------|
| **1.1–1.4** 長時間不在検出 (全モード) | 共有 60s しきい値でモード非依存の不在タイマー。暗転段階遷移とは独立 | `DimPowerPolicy.tick()` は `stage == .dimmed` の時のみ不在計測 (71行目) | **未実装**: 通常モード用不在タイマー、暗転段階からの分離 |
| **2.1–2.2** 顔フォールバック間引き | 長時間不在中の顔フォールバック実行頻度を低下。視覚処理/窓を暗転段階より低く | `PoseDetector.detect()` は姿勢失敗時に顔フェーズを **毎回** 実行 (119–141行目) | **未実装**: 間引き機構 + Session からのシグナル |
| **2.3** カメラ + FPS 上限不変 | カメラフレーム継続。推論 FPS 上限は段階値のまま (15/10) | `FrameThrottle.setLimit()` を `applyDimPowerStage()` で使用 | ✅ 変更不要 |
| **2.4** 長時間不在解除で顔頻度復帰 | 長時間不在終了時に顔フォールバックを毎推論へ戻す | 該当なし | **未実装**: 復帰パス |
| **3.1–3.4** 「顔のみ＝人物あり」の保持 | 顔実行時は `.personOnly` を返す。顔のみ人物が間引き間隔内で検出される。`personMissing` 表示則不変 | `synthesize()` でエンコード (79行目)。`updateState` で 0.5s デバウンス | **制約**: 間引き間隔 ≤ デバウンス、または復帰検出を特別扱い |
| **4.1–4.5** 不変項目 | 3秒確定、閾値、近側、フォールバック鎖、通知、カメラ稼働 | `PostureAnalyzer`、`PostureSessionManager`、`AlertPlayer` で強制 | ✅ 変更なし。回帰テスト必要 |
| **5.1–5.4** 計測 | 条件別視覚処理時間 + Energy Report (同端末/同セッション)。推定値なし | 5秒窓ログ存在。dim-mode-saving がテンプレート定義 | ✅ 既存再利用。通常モード長時間不在用に拡張 |

### アーキテクチャからの制約
- **新規依存なし** (Apple フレームワークのみ)
- **カメラ停止なし** (要件 2.3, 4.4 — dim-mode-saving 要件 5)
- **推論 FPS 上限変更なし** (要件 2.3 — `dimmed`/`dimmedAbsent` とも 10fps、ADR-0024)
- **単一ライター**: `PostureSessionManager` @MainActor が `snapshot.isPersonDetected`、`dimPowerPolicy` を所有
- **検出キュー分離**: `PoseDetector` は `detectionQueue` 上で実行。`@MainActor` 状態を直接読めない
- **ADR-0021 意味**: `synthesize(pose:faceBounds:)` は `pose ?? (faceBounds != nil ? .personOnly : .absent)` のまま — 顔実行時は必ず `.personOnly` を返す

---

## 3. 実装アプローチの選択肢

### 選択肢 A: `DimPowerPolicy` にモード非依存長時間不在トラッカーを追加

**説明**: `DimPowerPolicy` 内に並列の「長時間不在」状態マシンを追加。同じ `absentThreshold` を使用。`isProlongedAbsence: Bool` と `prolongedAbsenceTick(isPersonDetected:now:)` を暗転段階用 `tick()` とは分離して公開。

**修正ファイル**:
- `DimPowerPolicy.swift` — `prolongedAbsenceStart`, `isProlongedAbsence`, 新メソッド `tickProlongedAbsence()` を追加
- `PostureSessionManager.swift` — 新 tick を `updateState` (全フェーズ) で呼び、 `isProlongedAbsence` を `PoseDetector` に渡す
- `PoseDetector.swift` — `setProlongedAbsence(_: Bool)` または `detect()` 引数で受け取り、顔フォールバック間引きロジック実装

**互換性**:
- ✅ 既存 `DimPowerStage` 遷移を保持 (dim-mode-saving 不変)
- ✅ 閾値の単一ソース (`absentThreshold`)
- ✅ `PoseDetector` はメソッド引数またはセッターでシグナル受信 (スレッドセーフ: 検出キューで構造体コピーとともに呼出し)

**複雑さ**:
- `PoseDetector` が顔フェーズを間引く必要: 直近顔実行時刻を保持し、間引き間隔内ならスキップ
- 間引き間隔は **設計決定** (例: 2s, 5s, 10s) — 要件 3.2 (間隔内での復帰検出) に影響
- 間引き実行でも `Metrics.faceExecutedCount` / `faceTotalTime` を更新

**トレードオフ**:
| ✅ メリット | ❌ デメリット |
|------------|-------------|
| 新規ファイル最小化。既存閾値+タイマーロジック再利用 | `DimPowerPolicy` が二重責務に (暗転段階 + モード非依存不在) |
| 「長時間不在か」の単一真実源 | `PoseDetector` シグネチャ変更で呼出し側影響 (のみ `PostureSessionManager.captureOutput`) |
| 自然な適合: `DimPowerPolicy` が不在計時を既に所有 | 間引き間隔パラメータが設計決定事項に (設定可能 vs ハードコード) |

---

### 選択肢 B: 新規 `ProlongedAbsenceTracker` 値型 (Session 層)

**説明**: `NekozeFix/Session/ProlongedAbsenceTracker.swift` を新規作成 — 純粋値型で不在タイマー、閾値、`isProlongedAbsence` を所有。`DimPowerPolicy` は不変 (暗転モード専用)。`PostureSessionManager` が両方を所有し `updateState` でトラッカーを呼出し。

**作成/修正ファイル**:
- **新規**: `ProlongedAbsenceTracker.swift` (Session 層)
- `PostureSessionManager.swift` — トラッカーインスタンス追加、`updateState` で呼出し、状態を `PoseDetector` へ渡す
- `PoseDetector.swift` — 選択肢 A と同様

**互換性**:
- ✅ 責務の明確分離: 暗転段階 ≠ 長時間不在
- ✅ `DimPowerPolicy` は暗転モード専用のまま (CONTEXT.md 現定義準拠)
- ⚠️ CONTEXT.md は「長時間不在」を暗転モード専用と定義 — どちらにせよ **設計で CONTEXT 更新必須**

**トレードオフ**:
| ✅ メリット | ❌ デメリット |
|------------|-------------|
| 型ごとの単一責務が明確 | 新規ファイル + Session の新統合点 |
| 長時間不在ロジックを単体でテスト容易 | 二重の不在タイマー稼働 (暗転 + 長時間) — 整合性確保必要 |
| 「長時間不在はモード非依存」要件と整合 | 閾値値のわずかな重複 (軽減: トラッカーが `DimPowerPolicy` または共有定数から閾値取得) |

---

### 選択肢 C: ハイブリッド — Session にトラッカー、 `DimPowerPolicy` 最小変更

**説明**: `DimPowerPolicy` は不変 (暗転段階のみ)。`prolongedAbsenceStart: TimeInterval?` を `PostureSessionManager` に直接追加 (または小さな private 構造体)。共有閾値定数を使い `updateState` で `isProlongedAbsence` 計算し `PoseDetector` へ渡す。

**修正ファイル**:
- `PostureSessionManager.swift` — `prolongedAbsenceStart` 追加、`updateState` で `isProlongedAbsence` 計算、`PoseDetector` へ渡す
- `PoseDetector.swift` — 間引きロジック追加

**互換性**:
- ✅ `DimPowerPolicy` 変更なし (dim-mode-saving spec 不変)
- ✅ 新規コード最小
- ⚠️ Session の状態が増加 (dim-mode-saving の「小さな純粋ポリシー」パターン違反)

**トレードオフ**:
| ✅ メリット | ❌ デメリット |
|------------|-------------|
| 最速実装。新規ファイルなし | Session が「薄いオーケストレータ」から「状態保持」へ。肥大化リスク |
| dim-mode-saving への影響ゼロ | 長時間不在ロジックの単体テストが困難 |
| | 閾値が重複または `DimPowerPolicy.defaultAbsentThreshold` 参照 |

---

### 選択肢 D: `FrameThrottle` 内で顔フォールバック間引き (非推奨)

**説明**: `FrameThrottle` に「顔フォールバック間引き」サブモード追加。長時間不在時に `FrameThrottle` が「今回は顔スキップ」を通知。

**非推奨理由**: `FrameThrottle` は **推論 FPS 制限** (フレームタイムスタンプの時間ゲート)。顔フォールバック間引きは **別ポリシー** (不在状態に基づく Vision 顔リクエスト スキップ)。懸念事項が混在し、「間引き→条件化」順序保証 (ADR-0022/0024) を破る。

---

## 4. ギャップ要約と推奨

### 要件-アセット マップ

| 要件 | 既存アセット | ギャップ | 深刻度 |
|------|--------------|--------|--------|
| 1.1 | `DimPowerPolicy.tick()` | `.dimmed` 段階でのみ実行 | **未実装** |
| 1.2 | `DimPowerPolicy` 段階遷移 | 新状態「長時間不在」未モデル化 | **未実装** |
| 1.3 | `dimPowerPolicy.restored()` | 暗転段階のみ復帰。長時間不在は別リセット必要 | **未実装** |
| 1.4 | `DimPowerPolicy.defaultAbsentThreshold` | 共有 ✅ | — |
| 2.1 | `PoseDetector.detect()` | 顔フォールバック間引きなし | **未実装** |
| 2.2 | 計測ログ | 通常モード長時間不在の窓データ必要 | **部分的** |
| 2.3 | `FrameThrottle.setLimit()` | 既に使用。変更なし ✅ | — |
| 2.4 | `PoseDetector` + Session 連携 | 復帰パス未実装 | **未実装** |
| 3.1 | `PoseDetector.synthesize()` | 顔実行時は保持 ✅ | **制約** |
| 3.2 | `updateState` デバウンス (0.5s) | 間引き間隔で永続見逃し防止必要 | **不明** → 調査 |
| 3.3 | `PoseDetector.detect()` 通常経路 | 変更不要 ✅ | — |
| 3.4 | `updateState` 表示則 | 不変 ✅ | — |
| 4.1–4.5 | Domain/Session ロジック | 回帰テスト必要 | **テストギャップ** |
| 5.1–5.4 | Metrics ログ + Energy Report | 通常長時間不在へ拡張 | **拡張** |

### 工数・リスク評価

| アプローチ | 工数 | リスク | 根拠 |
|------------|------|--------|------|
| **A: DimPowerPolicy 拡張** | **M** (3–5 日) | **中** | 一つの型に二重責務。`PoseDetector` インターフェース変更。間引き間隔設計。 |
| **B: 新規 ProlongedAbsenceTracker** | **M** (3–5 日) | **低** | 責務分離明確。テスト容易。`DimPowerPolicy` の「小さな純粋ポリシー」パターン踏襲。 |
| **C: Session にインライン** | **S** (1–3 日) | **中** | 高速だが Session 肥大化。単体テスト困難。閾値ドリフトリスク。 |

### 推奨: **選択肢 B (新規 `ProlongedAbsenceTracker`)**

**理由**:
1. **アーキテクチャ整合性**: dim-mode-saving で `DimPowerPolicy` を「段階遷移の純粋値型」として導入。長時間不在は *別概念* (モード非依存) — 独自型がふさわしい。
2. **テスト容易性**: カメラ/暗転モードなしで不在タイマー + 間引き相互作用を単体テスト可能。
3. **CONTEXT.md 更新**: 要件で「設計フェーズで CONTEXT.md 定義更新」と明記。新規型で一般化が明示的に。
4. **将来拡張性**: 他 spec (バックグラウンド監視等) が長時間不在を必要とする場合、トラッカーが再利用可能。

**設計フェーズでの主要決定事項**:
1. **間引き間隔**: 長時間不在中の顔フォールバック頻度 (例: 2s/5s/10s)。要件 3.2「間引き間隔内での復帰検出」を満たす必要。トレードオフ: 低頻度 = 省電力大だが復帰検出遅延大。
2. **シグナル渡し**: `detectionQueue` 上の `PoseDetector` が `isProlongedAbsence: Bool` 必要。選択肢: (a) `detect()` 引数追加、(b) `PoseDetector.setProlongedAbsence(_:)` + ロック、(c) `FrameThrottle` 風設定。(a) が最もシンプルかつスレッドセーフ (呼出し毎に値渡し)。
3. **計測**: 間引き実行を `PoseDetector.Metrics` で計数するか？ はい — 実行時のみ `faceExecutedCount`、スキップ時は `faceSkippedCount` (間引き用は `faceThrottledCount` 追加で区別)。
4. **通常 vs 暗転 長時間不在**: 同じ間引き間隔か？ 異なるか？ (要件 2.2 は暗転比較のみ指定)。

### 設計フェーズへの持ち越し調査項目
1. **間引き間隔選定**: 候補間隔 (2s, 5s, 10s) で実機測定し、視覚処理時間 vs 復帰検出遅延を評価。要件 3.2「間引き間隔の範囲内」に関連。
2. **CONTEXT.md 用語**: 「長時間不在」の一般化 vs 新用語確定。現 CONTEXT は暗転モード専用定義。
3. `PoseDetector` インターフェース: `detect(sampleBuffer:orientation:isProlongedAbsence:)` 引数追加か、別途セッターか。`captureOutput` 呼出し箇所に影響。
4. **`personMissingGracePeriod` (0.5s) との相互作用**: 間引き間隔 > 0.5s の場合、長時間不在中に顔のみ人物が復帰しても顔実行間隔中は `personMissing` にちらつく。許容か？ (要件 3.4 は表示則不変 — ちらつきは表示変更)。設計で緩和必要 (例: 長時間不在中かつ間引きギャップ中は `isPersonDetected=true` を保持)。

---

## 5. アウトプット チェックリスト

- [x] 要件-アセット マップ (ギャップタグ付き)
- [x] 選択肢 A/B/C (根拠とトレードオフ付き)
- [x] 工数 (M) とリスク (中/低) + 正当化
- [x] 推奨: **選択肢 B 優先**; 間引き間隔、シグナル渡し、計測拡張、CONTEXT 更新を設計で検討
- [x] 調査項目繰越

---

## 6. 設計合成結果 (`/kiro-spec-design` より)

### 一般化

- **モード非依存長時間不在**: 要件 1.1–1.4, 2.1–2.4 で通常/暗転両モードでの長時間不在検出を要求。`DimPowerPolicy` (暗転段階遷移所有) を拡張する代わりに、別個の `ProlongedAbsenceTracker` 値型を作成。*不在計測* 能力を一般化し、*暗転段階遷移* を `DimPowerPolicy` に留める。インターフェース `tick(isPersonDetected:now:)` は現在および将来のモードを自然にサポート。
- **間引きをポリシーとして分離**: 顔フォールバック間引き (要件 2.1) は推論 FPS 制限 (`FrameThrottle`) とは別ポリシー。設計で分離: `ProlongedAbsenceTracker` が間引き間隔決定を所有し、`PoseDetector` がスキップを実行。懸念混在を回避 (選択肢 D 却下)。

### 採用 vs 新規

- **採用**: 既存 `DimPowerPolicy.defaultAbsentThreshold` (60s) を不在閾値に — 単一真実源、注入テスト可能
- **採用**: 既存 `FrameThrottle` / `MotionService` 受口 (FPS/頻度) — 新規間引き機構不要
- **新規**: `ProlongedAbsenceTracker` (新規値型) — モード非依存不在計測を所有する既存コンポーネントなし
- **新規**: `PoseDetector.detect(isProlongedAbsence:)` パラメータ — 最小インターフェース変更、スレッドセーフな値渡し
- **新規**: `Metrics.faceThrottledCount` — 既存計測を拡張し間引き効果を取得

### 簡素化

- **削除**: `DimPowerPolicy` 拡張 (選択肢 A) — 二重責務 (暗転段階 + モード非依存不在) を生む
- **削除**: Session インライン状態 (選択肢 C) — `DimPowerPolicy` で確立した「小さな純粋ポリシー」パターン違反
- **削除**: `FrameThrottle` サブモード (選択肢 D) — 推論 FPS 制限と顔フォールバックポリシーの混同
- **平坦化**: `ProlongedAbsenceTracker` が不在計測 **と** 間引き間隔決定 (`shouldExecuteFaceFallback`) を両方所有。別「間引きポリシー」コンポーネント不要。
- **単一間引き間引き間隔**: 通常/暗転 長時間不在で共通 5s 間隔 (要件 2.2 は暗転比較のみ指定。通常比較は計測で暗黙に)。実装・テストを簡素化。

### 主要設計決定の記録

| 決定 | 根拠 | トレーサビリティ |
|------|------|-----------------|
| **選択肢 B: 新規 `ProlongedAbsenceTracker`** | 責務分離明確、テスト容易、 `DimPowerPolicy` パターン踏襲 | 要件 1.1–1.4, 2.1–2.4 |
| **5s 間引き間隔** | バランス: 視覚処理削減 vs 復帰検出遅延。要件 3.2「間隔内」を満たす | 要件 2.1, 2.2, 3.2 |
| **`detect(..., prolongedAbsenceTracker:)` 引数** | Tracker 渡しで内部完結。`shouldExecuteAndRecordFaceFallback` で判定・記録をアトミック化 | 要件 2.1, 3.1 |
| **`Metrics.faceThrottledCount`** | 間引きスキップを姿勢スキップ (`faceSkippedCount`) と区別 | 要件 5.1 |
| **`ProlongedAbsenceTracker` を `NSLock` 内包のスレッドセーフ構造体に** | `MotionService.SharedState` パターン踏襲。MainActor/detectionQueue 両スレッドから安全に変更 | 要件 1.1–1.4, 2.1 |
| **`shouldExecuteAndRecordFaceFallback` で判定・記録をアトミック化** | `recordFaceExecution` 脱調問題解決。`PoseDetector` 内部で完結 | 要件 2.1, 2.4, 3.2 |
| **`faceDetectedHoldActive` ホールド機構** | 顔実行後間引き間隔内は `isPersonDetected=true` 維持。通常モード `personMissing` ちらつき防止 | 要件 3.2, 3.4 |
| **通常/暗転で同一間隔** | 実装簡素化。要件 2.2 は暗転比較のみ要求 | 要件 2.2 |
| **CONTEXT.md 一般化** | 「長時間不在」をモード非依存に書換え。「顔フォールバック間引き」/「顔検出ホールド」追加 | 境界コンテキスト |

### 繰越リスク
1. **間引き間隔の検証**: 5s は起点。実機測定で調整の可能性 (ADR 更新)。
2. **二重不在トラッカー整合性**: `DimPowerPolicy` + `ProlongedAbsenceTracker` が同一 `isPersonDetected`/`now` を受け取ること。結合テストで検証。
3. **ADR 作成**: `docs/adr/XXXX-face-fallback-throttling.md` で間引き間隔、ホールド機構、同一間隔決定を記録。

---

## 7. 設計レビュー ゲート 結果

- ✅ 要件網羅性: 全 21 件の数値要件 ID (1.1–1.4, 2.1–2.4, 3.1–3.4, 4.1–4.5, 5.1–5.4) をトレーサビリティ表でマッピング
- ✅ アーキテクチャ準備: コンポーネント境界明確 (`ProlongedAbsenceTracker`, `PoseDetector`, `PostureSessionManager`)、Swift シグネチャでインターフェース具体化
- ✅ 境界準備: Owns/Out-of/Allowed/Revalidation セクション完全記載
- ✅ 実行可能性: ファイル構成計画に新規 2 + 修正 5 + ADR 1 の具体的パス。孤立コンポーネントなし。並行実行安全 (Tracker 単体テストは PoseDetector/Session テストと独立)
- ✅ 機械的チェック: 全要件 ID 発見。境界セクション非空。ファイル構成計画具体的。孤立コンポーネントなし