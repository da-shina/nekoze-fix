# Brief: vision-fps-throttle

## Problem
カメラ入力FPSとVision実行FPSが独立制御されておらず、カメラのネイティブレート（30fps想定）の全フレームが推論に到達するため、判定に不要な高頻度推論がバッテリーを消費する。

## Current State
CameraSessionManagerはsessionQueue（制御）とdetectionQueue（推論）を分離し、alwaysDiscardsLateVideoFrames=trueで運用するが、FPS制限（activeVideoMin/MaxFrameDuration・間引き・スキップ処理）は存在しない。PostureSessionManager.captureOutputは全フレームでposeDetector.detectを同期実行する。入力FPS・推論FPSの個別計測は未実施である。

## Desired Outcome
カメラ入力FPSとVision実行FPSを独立制御し、現状実測値・15FPS・10FPSを比較した上で3秒確定判定の意味を変えずに推論FPSを制限し、推論待ち蓄積なく最新フレーム優先で動作する。

## Approach
captureOutputコールバックでのタイムスタンプ基準の早期破棄（間引き）＋最新フレーム優先＋重複実行防止。vision-face-conditionalの後に実施し、共有呼出点の処理順序を「間引き→条件化」と定義する。カメラセッション停止・再開時のFPS制御状態初期化を含む。

## Scope
- **In**: 入力FPS・推論FPSの個別計測、推論対象外フレーム早期破棄、時間基準（タイムスタンプ）選定、重複実行防止、無制限蓄積の回避（最新優先）、alwaysDiscardsLateVideoFramesの意味維持、停止・再開時の状態初期化、FPS設定方法の選定（根拠なき固定禁止）
- **Out**: 顔条件化ロジック自体（別spec）、MainActor hop削減（別spec）、3秒確定・角度/補正ロジックの変更、カメラ解像度・プリセット変更

## Boundary Candidates
- CameraSessionManager側のFPS制御（frameDuration/間引き）とSession側グレース（0.5s系ホールド等）の整合点
- 間引き判定（時間基準）と最新フレーム優先キューイングの方針

## Out of Boundary
- 顔検出の要否判断ロジックは扱わない（入力はvision-face-conditionalの結果を利用）
- snapshot書込み頻度・UI更新間引きは扱わない
- Motion・暗転モードには触らない

## Upstream / Downstream
- **Upstream**: vision-face-conditional（条件化後の成功/失敗率が間引き効果に影響）、nekoze-fix spec §4.2（3秒確定）・NFR 8.1（15fps以上構造）・0.5s系ホールド/EMA定数
- **Downstream**: mainactor-throttle（hop頻度は推論FPSに従属）、dim-mode-saving（暗転時FPS低下の前提インターフェース）

## Existing Spec Touchpoints
- **Extends**: なし（非機能最適化）
- **Adjacent**: nekoze-fix（§4判定タイミング・代替基準鎖・補正系を制約参照）、vision-face-conditional・mainactor-throttle（captureOutput共有シーム）

## Constraints
- 3秒連続猫背判定の既存仕様維持（フレーム間引きで判定時間の意味変更禁止）
- 姿勢角度・垂直ベクトル・回転/ミラー/aspect fit補正を壊さない
- FPS値を根拠なく固定せず既存設計に合った設定方法を選ぶ
- 計測シナリオ（通常/暗転/不在/復帰/猫背/長時間）での入力FPS・実行FPS・推論/待ち時間・CPUを記録し推定記載禁止
