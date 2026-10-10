# Brief: dim-mode-saving

## Problem
暗転モードでは表示輝度低下에도かかわらずカメラ・Vision・Motion処理が継続する可能性があり、画面点灯抑止とセンサー稼働が別々に制御されていないため省電力余地が残る。

## Current State
enterDimMode/exitDimModeはsavedBrightness保存→brightness=0.0＋snapshot.isDimmed=true（UI表現）で、監視・判定は継続する。wake lock（isIdleTimerDisabled）はsetPhaseがphase==.monitoringで強制し暗転解除操作と無関係に維持される。Motion/回転の起停はsetMotionRotationRunning経由で暗転は対象外とコメントされている。

## Desired Outcome
暗転中に必要な監視機能を維持しながら不要処理を削減し、通常モードよりバッテリー消費を低減する（NFR 9.2）。暗転時推論FPS低下・長時間不在時の更なる低下を検討し、カメラ停止は監視・復帰影響評価後のみ採用する。ユーザーの期待する監視動作を説明なく変更しない。

## Approach
暗転を省電力モード切替点として、vision-fps-throttleとmotion-frequencyの確定インターフェースを利用した段階的低下（通常→暗転→長時間不在）を設計する。輝度制御・wake lock・センサー稼働を独立制御し、各段階の復帰時間・検出精度を計測する。

## Scope
- **In**: 暗転中の必要/不要処理の区分、暗転時推論FPS低下モード、長時間人物不在時の更なる低下方式、カメラ停止の影響評価（採用は評価後のみ）、画面点灯抑止とカメラ・Motion稼働の分離制御、暗転移行・復帰の回帰
- **Out**: 通常時FPS・Motion率の決定自体（別specの結果を利用）、判定ロジック・通知仕様の変更、暗転UIデザイン変更、バックグラウンド監視の追加

## Boundary Candidates
- enter/exitDimMode・isDimmed・isIdleTimerDisabledの制御責務分離（表示 vs センサー稼働 vs スリープ抑止）
- 段階的低下の状態遷移（通常→暗転→長時間不在）と復帰則

## Out of Boundary
- 通常モードの推論・Motion頻度決定は扱わない
- カメラ権限・ライフサイクル（バックグラウンド停止）仕様の変更は扱わない
- 監視動作の縮小（検知停止等）を説明なく導入しない

## Upstream / Downstream
- **Upstream**: vision-fps-throttle（暗転時FPS低下の前提インターフェース）、motion-frequency（暗転時Motion率の前提）、nekoze-fix spec §6（暗転）・§8.3/8.4（スリープ抑止）・NFR 9.2
- **Downstream**: Phase G相当の回帰（暗転移行・復帰、復帰時間、通知遅延、長時間監視の蓄積・メモリ）

## Existing Spec Touchpoints
- **Extends**: なし（非機能最適化、監視継続の期待動作は維持）
- **Adjacent**: nekoze-fix（§6暗転・§8ライフサイクルを制約参照）、mainactor-throttle（isDimmed書込み共有）、motion-frequency（起停共有シーム）

## Constraints
- ユーザーの期待する監視動作を説明なく変更しない（カメラ停止は影響評価後のみ）
- 暗転中も姿勢検知・通知機能の継続が原則（nekoze-fix §6.2）
- 通常/暗転/不在/復帰/長時間の各シナリオで電力・復帰時間・精度を計測し推定記載禁止
