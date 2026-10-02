# PR#11 レビューコメント修正完了レポート

**修正日時**: 2026-10-02  
**対象PR**: #11 - feat: iOS 17回転移行・向き一本化＋基準線の実機整合  
**実施者**: OpenCode AI Agent

---

## 修正サマリー

CodeRabbitによる3つの未解決レビューコメントすべてを修正し、全テストが通ることを確認しました。

| # | 指摘内容 | 修正状況 | 変更ファイル数 |
|---|---------|---------|--------------|
| 1 | 校正値と基準ベクトルの整合性（design.md:255） | ✅ 完了 | 8ファイル |
| 2 | MotionService並行性・@MainActor隔離（design.md:282） | ✅ 完了 | 2ファイル |
| 3 | MotionUsageDescriptionTestsのXCTSkip化（54-62行） | ✅ 完了 | 1ファイル |

---

## 詳細修正内容

### Comment 1: 校正・角度比較設計の整合性（design.md Line 255）

**問題**: 重力⇔肩ライン直交⇔画像垂直の基準ベクトル切替時に、校正値（`referenceNearAngleDegrees`）が更新されず、同一物理姿勢で判定が変わる不具合の温床。

**修正内容**:
1. **PostureTypes.swift**: `ReferenceVectorSource` enum と `ResolvedReferenceVector` struct を追加
2. **PostureAnalyzer.swift**: `analyze()` 戻り値を `ResolvedReferenceVector` に変更、解決元を追跡
3. **CalibrationLogic.swift**: 
   - `ingest()` に `referenceSource` パラメータ追加
   - 基準ベクトル解決元が変わったら即時リセット
   - `CalibrationProgress.completed` に `referenceSource` 追加
4. **PostureSessionManager.swift**:
   - `applyCalibrationCompletion()` に `referenceSource` 追加
   - `snapshot.calibrationReferenceSource` で校正時の解決元を保存
   - 監視中に解決元が変わったら自動再校正トリガー
5. **テストファイル更新**: 7ファイル

**実装した方針**: 「基準ベクトル解決元が変わったら再校正」のトランジションポリシーを採用。向き変化時と同様の再校正フローで基準値・ゲートを破棄し `calibrating` へ遷移。

### Comment 2: MotionService並行性戦略（design.md Line 282）

**問題**: `OperationQueue`（motionQueue）とメインスレッドで `latestGravityInKeypointSpace`/`isRunning`/ホールド状態を非同期読み書き → データ競合。

**修正内容**:
1. **MotionService.swift**: クラス全体を `@MainActor` に変更
2. `motionManager.startDeviceMotionUpdates(to:)` のコールバック内で `Task { @MainActor in self?.ingest(...) }` でメインアクターに戻す
3. **MotionServiceTests.swift**: テストクラスを `@MainActor` に変更

**効果**: コンパイラによる静的データ競合検証が可能になり、実機でのヒーゼンバグを防止。

### Comment 3: MotionUsageDescriptionTestsのXCTSkip化（54-62行）

**問題**: `repoFileURL` が `nil` を返す環境（CI shallow clone等）で `XCTUnwrap` → テスト失敗。

**修正内容**:
- `testSourceInfoPlistContainsMotionWording()`
- `testProjectDeclaresMotionKeyForGeneratedPlist()`
の2テストで `XCTUnwrap` → `guard let ... else { throw XCTSkip(...) }` に変更

**効果**: リポジトリファイルが見つからない環境ではスキップ扱い、CI安定化。

---

## 変更ファイル一覧

### 実装ファイル (8)
- `NekozeFix/Types/PostureTypes.swift` - 型定義追加
- `NekozeFix/Domain/PostureAnalyzer.swift` - 解決元追跡
- `NekozeFix/Domain/CalibrationLogic.swift` - 再校正トリガー
- `NekozeFix/Session/PostureSessionManager.swift` - 校正時保存・監視中検知
- `NekozeFix/Services/MotionService.swift` - @MainActor化
- `NekozeFixTests/MotionUsageDescriptionTests.swift` - XCTSkip化

### テストファイル (7)
- `NekozeFixTests/MotionServiceTests.swift` - @MainActor対応
- `NekozeFixTests/CalibrationLogicTests.swift` - referenceSource対応・完了ケース更新
- `NekozeFixTests/PostureAnalyzerTests.swift` - ResolvedReferenceVector対応
- `NekozeFixTests/PostureAnalyzerResolveTests.swift` - 同上
- `NekozeFixTests/PostureSessionManagerTests.swift` - applyCalibrationCompletion引数追加
- `NekozeFixTests/ReferenceVectorHandoffTests.swift` - 同上
- `NekozeFixTests/ReferenceVectorRotationTests.swift` - 同上

---

## 検証結果

```
** TEST SUCCEEDED **
```

- 全テストスイート通過
- ビルド成功（警告のみ、エラーなし）
- 既存機能の回帰なし

---

## 設計ドキュメント更新の必要性

以下のドキュメントも整合性のため更新推奨:
- `.kiro/specs/nekoze-fix/design.md` - Comment 1/2 の設計記述更新
- `.kiro/specs/nekoze-fix/tasks.md` - 完了タスクの記録