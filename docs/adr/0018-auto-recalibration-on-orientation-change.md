# 向き変化時の自動再校正

重力基準化により判定が端末向きに依存するため、monitoring中の向き変化を検出したら旧基準（基準角度・基準距離・ロック側）と猫背ゲートを破棄してcalibratingへ自動遷移し、再校正完了まで監視を停止する。ズレた基準での継続監視による誤通知・見逃しを防ぐことを、5秒の再校正コストより優先する。

## Considered Options

- 旧基準を保持し「要再校正」表示で監視継続：監視は止まらないが、系統的にズレた基準での判定が続き、degraded-mode の追加設計が要る
- バナーのみ（自動遷移なし）：介入は最小だが、再校正忘れのまま誤判定が続く
- 自動再校正遷移（採用）：安全側。回転は頻繁な操作ではなく、トリガは既存 `DeviceOrientationMonitor.currentVideoOrientation` の購読のみでモニタ無改修

## Consequences

- Session状態機械に monitoring→calibrating の自動遷移が加わる（design.md Boundary 更新、grill Q3/Q5/Q6/Q7）
- calibrating中・idleの向き変化は対象外。回転中transientの7.2配線とは別物であり、そちらは既存ギャップのまま残す
- 再校正完了まで通知が出ない無監視時間が生じる
