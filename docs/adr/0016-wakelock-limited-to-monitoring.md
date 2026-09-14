# wake lock の所有権を「監視中」に限定（phase 不変条件）

## 概要

ユーザー要望により、自動スリープ抑止の範囲を「アクティブ中常時」（ADR 0015）から「アクティブかつ監視中」へ縮小する。`UIApplication.shared.isIdleTimerDisabled` を `snapshot.phase == .monitoring` と等値の不変条件として再定義し、phase 遷移の唯一の書き込み経路 `setPhase()` で強制する。ADR 0015 は本 ADR により superseded。

## 詳細

- 不変条件: `isIdleTimerDisabled == (phase == .monitoring)`。全フェーズ遷移を `setPhase()` 経由に統一し、直接代入を廃止して同期漏れを構造的に防ぐ
- ON になるのは `startMonitoring()` / 校正完了（`applyCalibrationCompletion`）の監視遷移時のみ。OFF は監視停止（明示 `stopMonitoring`）、監視中の背面退避（`setPhase(.idle)`）、校正やり直し、権限画面への遷移で自動成立
- `bootstrap()` は wake lock を直接触らない（非監視フェーズなので OFF のままが正しい）
- `enterDimMode()` / `exitDimMode()` は引き続き輝度のみ扱う。監視中の暗転では phase が `.monitoring` のままなので点灯が継続し、暗転の解除操作と無関係（要件 8.4）
- `.inactive`（通知シェード開）では phase が変わらず wake lock も不変。退避は `.background` 遷移時のみ
- 抑止対象は OS の自動スリープのみ（電源ボタンロックには介入しない）は ADR 0015 から不変

## Considered Options

- **アクティブ中常時 ON（ADR 0015）**: 「アプリがアクティブな時」の直訳で書き込み点も少ないが、idle・校正画面での点灯維持がバッテリーを不必要に消費する。ユーザーが監視中限定へ方針変更 → superseded
- **phase == .monitoring 不変条件（採用）**: 書き込み経路が `setPhase` 1本に集約され、監視を離れる全経路（退避・停止・校正・権限）が同じ式で自動的に OFF になる。暗転 enter/exit を独立して気にする必要がない
- **暗転 enter/exit で ON/OFF（旧 ADR 0013）**: `startMonitoring()` 内の `exitDimMode()` 経由で意図せず解除されるバグ経路があり、監視停止の OFF も担保できない → 棄却（ADR 0015 で済）

## 結果

要件 8.3/8.4 を改訂（抑止は監視中に限定、監視未開始は OS 標準へ復元）。NFR 9.1 の点灯常時前提の再実測は失効し、監視継続＝点灯前提の実機確認に戻る。
