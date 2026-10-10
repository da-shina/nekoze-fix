# Brief: motion-frequency

## Problem
MotionServiceがdeviceMotionUpdateInterval=1/30（30Hz）で重力更新し、毎サンプルTask { @MainActor } hopでingestするため、カメラフレーム頻度と独立に高頻度更新コストが発生する可能性がある。電力寄与は未計測である。

## Current State
MotionService（@MainActor、113行）はstartDeviceMotionUpdatesをmotionQueue（直列）で受信し毎サンプルMain hopする。latestGravityInKeypointSpace＋0.5sホールドでPostureAnalyzerの垂直解決鎖（重力→両肩ライン直交→画像垂直）に供給する。起停はsetMotionRotationRunning経由（暗転中継続・背景停止）。DeviceRotationServiceが回転角専用で併存する。

## Desired Outcome
重力更新頻度と利用頻度を計測した上で30Hz（現状基準）・15Hz・10Hzを比較し、垂直補正・回転/ミラー整合を保ちながら最適な更新頻度を選定する。Motion負荷が小さい場合は変更を見送り効果の高い箇所を優先する。

## Approach
計測先行で寄与を確認し、カメラフレーム頻度とMotion更新を独立化＋最新値優先＋不要hop回避。他specと並列実施可能な独立モジュール変更とし、nil耐性（代替鎖へのフォールバック）を確認する。

## Scope
- **In**: 重力更新頻度・利用頻度の計測、カメラFPSとMotion頻度の独立化、最新値優先・不要UI更新/hop回避、垂直補正・端末回転・ミラー補正整合確認、30/15/10Hzの電力・精度比較、効果小の場合の見送り判断
- **Out**: Vision推論・MainActor hop集約（別spec）、判定閾値・代替基準鎖ロジックの変更、暗転時の起停方針変更（別spec dim-mode-saving）

## Boundary Candidates
- MotionService.updateInterval/holdDurationとPostureAnalyzerのnil耐性（代替鎖フォールバック）の契約点
- setMotionRotationRunning起停一本化とdim-mode-savingの共有則

## Out of Boundary
- カメラ・Visionパイプラインには触らない
- 暗転中の省電力モード切替ロジックは扱わない（インターフェース提供に留める）
- DeviceRotationServiceの回転角配信方式は変更しない（整合確認のみ）

## Upstream / Downstream
- **Upstream**: nekoze-fix spec §4.1・§4.9（天方向基準・代替基準鎖・復帰則）、MotionServiceTests・ReferenceVector系テスト
- **Downstream**: dim-mode-saving（暗転時のMotion率低下が本specのインターフェースに依存）、Phase G相当の回帰（回転補正・復帰時間）

## Existing Spec Touchpoints
- **Extends**: なし（非機能最適化）
- **Adjacent**: nekoze-fix（§4天方向基準・§7デバイス向きを制約参照）、dim-mode-saving（setMotionRotationRunning共有シーム）

## Constraints
- 垂直補正・端末回転・ミラー補正の整合性維持、代替鎖フォールバック動作の維持
- 電力改善と判定精度の両方を比較し、効果未確認の変更は追加しない
- 実測なき省電力率記載禁止、未計測項目は明記
