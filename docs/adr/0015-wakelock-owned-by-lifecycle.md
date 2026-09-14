# wake lock の所有権を暗転モードからライフサイクルへ移管

## 概要

要件 8.3/8.4（アプリがアクティブな間は自動スリープを無効化）に対応するため、`UIApplication.shared.isIdleTimerDisabled` の所有権を画面暗転モードからアプリライフサイクル（PostureSessionManager の scenePhase 配線）へ移管する。ADR 0013 は暗転文脈での wake lock を定めたが、本 ADR により暗転 enter/exit は wake lock に触れない。

## 詳細

- アクティブ中（初回 bootstrap 完了時〜 `.background` 遷移まで）は監視・暗転の有無にかかわらず `isIdleTimerDisabled = true` を維持する（8.3, 8.4）
- 書き込み点はライフサイクル処理のみ:
  - `bootstrap()` 完了 → true（初回起動。scenePhase の onChange は初期値では発火しないため bootstrap 側で担保）
  - `handleWillEnterForeground()` → true（冪等。`.inactive → .active` の戻りも含む）
  - `handleDidEnterBackground()` → false（唯一の OFF 点）
- `enterDimMode()` / `exitDimMode()` は輝度のみ扱い、`isIdleTimerDisabled` を変更しない。暗転解除で自動スリープが復活しない（8.4）
- `.inactive`（通知シェード・コントロールセンター開）では何もしない。フォアグラウンド滞留中の点灯と暗転は維持される
- 抑止対象は OS の自動スリープのみ。電源ボタンロックや OS の強制ロック設定には介入しない（requirements.md Adjacent Expectations）

## Considered Options

- **暗転 enter のみ ON（旧 ADR 0013）**: 非監視中の画面オフを防げず、監視開始前や idle 画面でスリープして意図に反する → 棄却
- **ライフサイクル常時 ON（採用）**: 「アプリがアクティブな時は自動スリープ無効」という要件文と1対1。書き込み点が2箇所に集約され、暗転との相互作用バグ（exitDimMode による解除）が構造的に発生しない
- 監視中のみ ON: 校正画面・設定操作中のスリープが残る。要件が「アプリがアクティブな時」なので棄却

## 結果

`isIdleTimerDisabled` はライフサイクルの不変条件（フォアグラウンド滞留中 = true、バックグラウンド = false）となり、暗転モードは輝度だけの関心事になる。NFR 9.1（1時間 15% 以下）は自動スリープ抑止分の消費を含む前提で実機確認する。
