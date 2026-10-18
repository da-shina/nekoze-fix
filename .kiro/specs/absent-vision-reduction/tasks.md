# Tasks: absent-vision-reduction

## Phase 1: Foundation

- [ ] 1. テスト基盤と共有ユーティリティの整備
  - `ProlongedAbsenceTracker` 用のテストヘルパー（不正閾値・間隔注入、時間モック、スナップショット比較）を `NekozeFixTests/TestUtilities/` に追加
  - `PoseDetector` 間引きテスト用の時刻注入可能な `ProlongedAbsenceTracker` と合成フレーム生成ユーティリティを作成（final クラスのモック化は避け、値型の時刻注入でテスト可能にする）
  - 既存の `DimPowerPolicyTests` パターンに合わせ、単体テストのテンプレートを整理
  - 完了条件: テストビルドが通過し、ヘルパーが `ProlongedAbsenceTrackerTests` / `PoseDetectorTests` で利用可能
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.4, 3.1, 3.2, 3.3_
  - _Boundary: Test Infrastructure_

## Phase 2: Core Implementation

- [ ] 2. `ProlongedAbsenceTracker` 実装 (Session層・スレッドセーフ構造体)
  - `NekozeFix/Session/ProlongedAbsenceTracker.swift` を新規作成
  - `NSLock` 内包、`@unchecked Sendable` 構造体として実装
  - プロパティ: `absentThreshold`、`faceFallbackThrottleInterval`、`isProlongedAbsence`、`absenceStart`、`lastFaceExecutionTime`、`lastFaceDetectedTime`
  - メソッド: `tick(isPersonDetected:now:)` → `Bool`、不在計測・遷移・ホールド時刻更新
  - メソッド: `shouldExecuteAndRecordFaceFallback(now:)` → `Bool`、間引き判定と実行時刻のアトミック更新
  - メソッド: `recordFaceDetected(now:)`、ホールド時刻更新
  - プロパティ: `faceDetectedHoldActive` → `Bool`、長時間不在中かつホールド期間内なら true
  - メソッド: `reset()`、全状態リセット
  - メソッド: `snapshot()` → `Snapshot`、テスト・ログ用
  - イニシャライザで不正値を既定値（60s / 5s）にフォールバック
  - 完了条件: 構造体がコンパイル通過し、`snapshot()` で状態が取得可能
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.4, 3.2, 3.4_
  - _Boundary: ProlongedAbsenceTracker_

- [ ] 3. `ProlongedAbsenceTracker` 単体テスト
  - `NekozeFixTests/ProlongedAbsenceTrackerTests.swift` を新規作成
  - テストケース: 初期状態、`isProlongedAbsence == false`
  - テストケース: 不正閾値・間隔は既定値（60s / 5s）にフォールバック
  - テストケース: 遷移 — 通常→長時間不在（しきい値超過）、人物再検出前/後、解除
  - テストケース: 閾値境界 — 59.9s / 60.0s / 60.1s で遷移確認
  - テストケース: 間引き判定 — 実行可/不可/実行後リセット、`shouldExecuteAndRecordFaceFallback` のアトミック性
  - テストケース: ホールド機構 — `faceDetectedHoldActive` が顔実行後間引き間隔内で true、長時間不在解除で false
  - テストケース: リセット動作、無効時刻無視
  - 完了条件: 全テストがパスし、カバレッジが主要分岐を網羅
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.4, 3.2, 3.4_
  - _Boundary: ProlongedAbsenceTracker_

- [ ] 4. `PoseDetector` 間引き実装 (Services層)
  - `NekozeFix/Services/PoseDetector.swift` を修正
  - `Metrics` に `faceThrottledCount: Int` 追加
  - `detect(sampleBuffer:orientation:prolongedAbsenceTracker:)` シグニチャ変更（Tracker 渡し）
  - 長時間不在中かつ姿勢観測ゼロ件時: Tracker `shouldExecuteAndRecordFaceFallback(now:)` 呼び出し
    - true なら顔リクエスト発行、`faceExecutedCount++`、`faceTotalTime` 記録、結果 `.personOnly` / `.absent` 返却、Tracker `recordFaceDetected(now:)` 呼び出し
    - false なら即 `.absent` 返却、`faceThrottledCount++`
  - 長時間不在でない場合: 従来通り毎回顔フォールバック実行、`faceSkippedCount` は姿勢あり時のみ
  - `synthesize` 意味不変確認（既存テストで回帰確認）
  - 完了条件: ビルド通過、間引き有効/無効/復帰/ホールドが単体テストで確認可能
  - _Requirements: 2.1, 2.2, 2.4, 3.1, 3.2, 3.3_
  - _Boundary: PoseDetector_

- [ ] 5. `PoseDetector` 単体テスト拡張
  - `NekozeFixTests/PoseDetectorTests.swift` を拡張
  - テストケース: 間引き有効時の顔スキップ（`.absent` 返却、`faceThrottledCount++`）
  - テストケース: 間引き無効時の毎回実行（`faceExecutedCount` インクリメント）
  - テストケース: Metrics 計数 — `faceThrottledCount` / `faceExecutedCount` / `faceSkippedCount` / `faceTotalTime` / `poseTotalTime`
  - テストケース: 復帰時毎回実行（Tracker リセット後）
  - テストケース: 合成則不変（`synthesize` 既存テストで回帰確認）
  - 完了条件: 全テストパス、間引き/復帰/非長時間不在の各パスで Metrics 正確
  - _Requirements: 2.1, 2.2, 2.4, 3.1, 3.2, 3.3_
  - _Boundary: PoseDetector_

- [ ] 6. `PostureSessionManager` 統合 (Session層)
  - `NekozeFix/Session/PostureSessionManager.swift` を修正
  - `prolongedAbsenceTracker: ProlongedAbsenceTracker` インスタンス変数追加（イニシャライザで閾値・間隔注入）
  - `updateState(presence:...)` 内で `tracker.tick(isPersonDetected: snapshot.isPersonDetected, now:)` 呼び出し
    - 戻り値で `isProlongedAbsence` 変化検知、ログ出力（任意）
    - `!isNowProlonged && wasProlonged` なら `tracker.reset()` 呼び出し
    - **ホールド抑制**: `tracker.faceDetectedHoldActive` なら `snapshot.isPersonDetected = true`（`personMissing` 抑制）
  - `captureOutput` 内で Tracker インスタンスを `poseDetector.detect(sampleBuffer:orientation:prolongedAbsenceTracker: tracker)` に渡す
    - 間引き判定・顔実行・ホールド更新は `detect()` 内部で完結
  - 既存 `DimPowerPolicy` 結合（`dimPowerPolicy.tick` 呼び出し）は変更せず併存
  - 完了条件: ビルド通過、通常/暗転それぞれで長時間不在遷移・解除・ホールド抑制・復帰が結合テストで確認可能
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.4, 3.1, 3.2, 3.3, 3.4_
  - _Boundary: PostureSessionManager_
  - _Depends: 2, 4_

- [ ] 7. 計測ログ拡張 (`faceThrottledCount` 出力)
  - `PostureSessionManager.logMetricsSnapshot()` を修正
  - 既存 5秒窓ログ `[NekozeFix Metrics]` に `faceThrottledCount` を追加出力
  - `PoseDetector.Metrics` から値取得し、フォーマットに追加
  - 完了条件: 実機ログで `faceThrottledCount` が出力され、間引き効果が定量確認可能
  - _Requirements: 5.1, 5.2, 5.3, 5.4_
  - _Boundary: PostureSessionManager, Metrics_
  - _Depends: 4, 6_

## Phase 3: Integration & Wiring

- [ ] 8. 依存注入と初期化順序の整備
  - `PostureSessionManager.init` で `ProlongedAbsenceTracker` を生成し保持（閾値は `DimPowerPolicy.defaultAbsentThreshold`、間隔は 5.0 秒で注入）
  - `DimPowerPolicy` と `ProlongedAbsenceTracker` が同一 `absentThreshold` を参照することを確認（単一ソース）
  - `enterDimMode` / `exitDimMode` / `startMonitoring` / `stopMonitoring` / `handleDidEnterBackground` / `handleWillEnterForeground` で Tracker のリセット/再開が適切に動作することを確認
  - 完了条件: 全ライフサイクル経路で Tracker 状態が正しく遷移し、DimPowerPolicy と併存して乖離しない
  - _Requirements: 1.1, 1.3, 1.4, 2.4_
  - _Boundary: PostureSessionManager, ProlongedAbsenceTracker, DimPowerPolicy_
  - _Depends: 2, 6_

## Phase 4: Testing & Validation

- [ ] 9. `PostureSessionManager` 結合テスト
  - `NekozeFixTests/PostureSessionManagerTests.swift` を拡張
  - テストケース: 通常モード長時間不在遷移・解除（`tick` → `isProlongedAbsence` → 解除で `reset`）
  - テストケース: 暗転モード長時間不在遷移・解除（暗転操作後 `dimmed()` → 不在継続 → `dimmedAbsent` 相当 → 解除）
  - テストケース: 暗転解除での通常復帰（`exitDimMode` → `restored()` + Tracker `reset()`）
  - テストケース: PoseDetector 間引き連携（`isProlongedAbsence` 渡し・実行記録・`faceThrottledCount` 計数）
  - テストケース: DimPowerPolicy との併存確認（二重不在計測が乖離しない）
  - テストケース: ホールド抑制（`faceDetectedHoldActive` 時に `isPersonDetected` 維持）
  - 完了条件: 全テストパス、通常/暗転それぞれで遷移・解除・ホールド・復帰が検証済み
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.4, 3.1, 3.2, 3.3, 3.4_
  - _Boundary: PostureSessionManager, ProlongedAbsenceTracker, DimPowerPolicy, PoseDetector_
  - _Depends: 2, 3, 4, 5, 6_

- [ ] 10. 既存回帰テストの全段階再実行
  - `FrameThrottleTests` / `MotionServiceTests` / `DimPowerPolicyTests` / `MainHopGateTests` を全条件で再実行
  - 間引き導入による既存機能（3秒確定・閾値・近側選択・代替鎖・通知仕様・カメラ稼働・FPS上限・Motion頻度）の不変を確認
  - 完了条件: 全既存テストスイートがパスし、回帰なし
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_
  - _Boundary: FrameThrottle, MotionService, DimPowerPolicy, MainHopGate, PostureAnalyzer, AlertPlayer_

- [ ] 11. 実機 E2E テストと性能計測
  - 実機（iOS 18.7.7 以上）で以下条件を測定・記録:
    - 条件: 通常モード長時間不在 / 暗転モード長時間不在 / 暗転段階（在席） / 通常モード在席 / 長時間監視
    - 指標: 視覚処理量（5秒窓ログ `faceThrottledCount` / `faceExecutedCount` / `faceTotalTime` / `poseTotalTime`）、電力指標（Xcode Energy Report: Average Energy Impact ゲージ色評価 + Average Component Utilization 領域別%）
    - 復帰検出遅延（間引き間隔 5s 以内であること確認）
    - 長時間監視での安定性（メモリリーク・クラッシュなし）
  - 記録形式: dim-mode-saving 実測テンプレート準拠（条件・電力・復帰時間・精度・未計測明記・推定値禁止）
  - 完了条件: 全条件で実測値取得、暗転長時間不在の視覚処理量が暗転段階より低いことを実測確認、推定値なし
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 2.2_
  - _Boundary: Metrics, Energy Report_
  - _Depends: 7, 8_

- [ ] 12. ADR 作成とドキュメント同期
  - `docs/adr/XXXX-face-fallback-throttling.md` を作成（連番で次 ADR 番号割当）
  - 記録内容: 間引き間隔 5s の決定根拠、`NSLock` スレッドセーフ構造体採用理由、`shouldExecuteAndRecordFaceFallback` アトミック化、`faceDetectedHoldActive` ホールド機構、同一間隔（通常/暗転）の決定、チラつき防止ホールド機構
  - `CONTEXT.md` 用語（長時間不在・不在しきい値・顔フォールバック間引き・顔検出ホールド）が設計と整合しているか確認
  - `design.md` の Grilling Decisions と ADR 参照を同期
  - 完了条件: ADR ファイル作成、用語集・設計書が最新決定と整合
  - _Requirements: (設計判断の記録)_
  - _Boundary: Documentation_

---

## Task Summary

- **Total**: 12 major tasks, ~45 sub-task details
- **Requirements Coverage**: All 20 requirement IDs (1.1–1.4, 2.1–2.4, 3.1–3.4, 4.1–4.5, 5.1–5.4) mapped
- **Parallel Tasks**: 3, 5, 10 can run in parallel after foundation (2, 4, 7)
- **Average Size**: 1-3 hours per sub-task
- **Execution Order**: Foundation (1) → Core (2-7) → Integration (8) → Validation (9-12)
- **Key Dependencies**: 2→3, 4→5, 2/4→6, 6/2→8, 2/3/4/5/6→9, 7/8→11, 8→11