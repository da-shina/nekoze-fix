# Roadmap

## Overview
NekozeFix iOSアプリのバッテリー消費削減プロジェクト。Vision顔検出条件化・推論FPS制限・MainActor hop削減・Motion頻度調整・暗転省電力の5領域を独立specに分解し、姿勢検知精度と既存機能を維持しながら不要な推論・タスク生成・UI更新を削減する。漸進的アプローチを採用し、P0から順に実装して各specで計測・回帰を行い、効果未確認の変更は追加しない。

## Approach Decision
- **Chosen**: (A)漸進的サブシステム別 — 顔条件化→FPS制限→MainActor→Motion→暗転の順に独立spec化
- **Why**: リスク最小、効果検証が各specで明確、共有シーム（captureOutput→processDetection）の処理順序を定義できる
- **Rejected alternatives**: (B)パイプライン集中スロットル — 早期効果は大きいが3領域結合で回帰特定が困難なため不採用。(C)全体適応型省電力モード — 長時間・不在時の削減は大きいがUX期待変更リスクがあるため、暗転のみ独立specとして分離し全体適応化は見送り

## Scope
- **In**: Vision顔検出条件化、推論FPS制限（15/10比較）、MainActor hop削減、Motion頻度調整（30/15/10比較）、暗転中省電力、変更前後の計測記録、回帰テスト追加
- **Out**: バックグラウンド監視、判定ロジック自体の変更（角度・距離閾値、3秒確定の意味変更）、UIデザイン変更、統計・永続化・クラウド機能

## Constraints
- iOS 17+ / フロントカメラ必須、アプリ起動中のみ監視（バックグラウンド監視なし）
- 3秒連続確定判定の意味を変えない（フレーム間引きで判定時間の意味変更禁止）
- 天方向基準・代替基準鎖（重力→両肩ライン直交→画像垂直）・回転/ミラー/aspect fit補正を壊さない
- NFR 8.1（キーポイント検出15fps以上）との整合を検証で確認する（入力FPSと推論FPSを独立計測）
- NFR 9.1/9.2（1時間15%以下、暗転時は通常より低消費）は目標値として実測検証し、推定値記載禁止
- 新規依存なし（Vision/AVFoundation/CoreMotionのみ）、ネットワーク送出禁止、基準姿勢はメモリのみ
- 既存ユーザー変更を破棄しない、無関係リファクタリング禁止
- 実測していない省電力率・持続時間の推定記載禁止、未計測項目は明記

## Boundary Strategy
- **Why this split**: 5領域の変更点が別ファイル・関数に局在（PoseDetector / CameraSessionManager+Session / captureOutput hop / MotionService / enterDimMode系）し独立検証可能。P0→P1の効果順に依存を並べ、Motionのみ並列可
- **Shared seams to watch**: captureOutput→processDetection呼出点（spec 1・2・3が交差、順序: 間引き→条件化→hop削減）、SessionSnapshot書込み（spec 3・5）、setMotionRotationRunning起停一本化（spec 4・5）、0.5s系ホールド・EMA・信頼度閾値（spec 1・2が検出率に影響）

## Specs (dependency order)
- [x] vision-face-conditional -- PoseDetector顔検出の条件付き実行（P0）。Dependencies: none
- [x] vision-fps-throttle -- Vision推論FPS制限と入力FPS独立制御（P0）。Dependencies: vision-face-conditional
- [x] mainactor-throttle -- MainActor hop削減とsnapshot更新最適化（P1）。Dependencies: vision-fps-throttle
- [x] motion-frequency -- CoreMotion更新頻度の調整（P1）。Dependencies: none
- [x] dim-mode-saving -- 暗転モード中の省電力化（P1）。Dependencies: vision-fps-throttle, motion-frequency
