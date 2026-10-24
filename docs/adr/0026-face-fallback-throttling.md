# 顔フォールバック間引き（長時間不在中のVision負荷削減）

長時間不在中に姿勢観測ゼロ件時に実行する顔フォールバックの実行頻度を間引き間隔（既定5秒）で制限し、Vision負荷とバッテリー消費を削減する。`ProlongedAbsenceTracker`（Session層）が間引き判定とホールド状態を単一所有し、`PoseDetector`（Services層）がTracker経由で間引きを実行する。

## 詳細

- **間引き間隔**: 既定5秒（`faceFallbackThrottleInterval`）。長時間不在中かつ姿勢観測ゼロ件時のみ適用。非長時間不在時は従来通り毎回顔フォールバックを実行。
- **スレッドセーフ性**: `ProlongedAbsenceTracker` はクラス（`@unchecked Sendable`）で内部に `NSLock` を持ち、`tick` / `shouldExecuteAndRecordFaceFallback` / `recordFaceDetected` / `faceDetectedHoldActive` / `reset` / `snapshot` を同一ロックで直列化する。`MotionService.SharedState` と同パターン。
- **アトミック化**: `shouldExecuteAndRecordFaceFallback(now:)` は「間引き判定＋実行時刻記録」をロック下でアトミックに行う。二重実行や時刻競合を防ぐ。
- **ホールド機構**: `recordFaceDetected(now:)` で顔実行後の時刻を記録し、`faceDetectedHoldActive(now:)` で間引き間隔内なら `true` を返す。`PostureSessionManager.updateState` で表示用 `isPersonDetected` を `true` に維持し、`personMissing` ちらつきを防止する。
- **同一間隔**: 通常モード・暗転モードで同一の間引き間隔（5秒）を使用。段階別の違いは設けない（複雑化と境界違反を避けるため）。
- **不在しきい値**: 既定60秒（`DimPowerPolicy.defaultAbsentThreshold` 共用）。`ProlongedAbsenceTracker` は `DimPowerPolicy` と独立に動作し、暗転段階遷移とは関係なく長時間不在を判定する。

## 検討した選択肢

- 段階別の間引き間隔（通常3秒／暗転5秒）：実測複雑化と境界定義の追加を招く（却下、同一間隔を採用）
- `Date`（暦時刻）での経過時間計測：壁時計変更の影響を受けるため却下（単調時計 `CACurrentMediaTime` 系を採用）
- 構造体ではなくクラス採用：検出キューとMainActor間で同一インスタンスを安全に共有するためクラスが必要（採用）

## 今後の対応

- [ ] 間引き間隔5秒の妥当性を実測記録で見直し、必要なら設計変更（ADR更新）
- [ ] 通常・暗転の長時間不在それぞれで電力・復帰時間・精度を実測記録（推定記載なし、未計測明記）
- [ ] 不在しきい値60秒の妥当性を実測記録で見直す（design再検証トリガー）
