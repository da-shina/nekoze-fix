# Brief: mainactor-throttle

## Problem
PostureSessionManager.captureOutputが毎フレームTask { @MainActor in ... }を生成し、snapshot書込み・processDetectionをMainActorへhopさせるため、フレームレートに比例したタスク生成・UI更新がバッテリーとCPUを消費する。snapshot.videoAspectRatio等の不変値更新も毎フレーム行われる。

## Current State
captureOutput（nonisolated）はdetectionQueue上でdetect同期実行後、毎フレームMain hopしてsnapshot.videoAspectRatio更新＋processDetectionを実行する。deliverRotationAngles・deviceFinalizedHandler・restartCameraPipeline等にもTask hopが分散する。Main渡しまでの待ち時間・蓄積状況の計測は未実施である。

## Desired Outcome
姿勢判定の継続性を維持しながらUI更新のみを独立最適化し、不要な中間結果破棄・最新結果優先・不変値更新回避によりMainActorタスク投入頻度を削減する。

## Approach
判定処理と表示処理の分離を軸に、hop頻度削減＋snapshot書込みバッチ化＋不変値スキップ。単純な受け渡し間引きではなく判定継続性を担保し、actor isolation・データ競合に配慮する。vision-fps-throttle後に実施し、推論FPS確定後のhop頻度を最適化する。

## Scope
- **In**: フレーム毎Task生成箇所の洗い出し、Main渡し待ち時間・蓄積計測、UI不要中間結果の破棄・最新優先、不変値（videoAspectRatio等）更新回避、判定処理と表示処理の分離、actor isolation・データ競合対応
- **Out**: 推論FPS自体の制限（別spec）、顔条件化（別spec）、判定閾値・3秒確定ロジックの変更、UIデザイン変更

## Boundary Candidates
- captureOutput→processDetection呼出点のhop集約方針（間引き→条件化→hop削減の最終段）
- snapshot書込みのバッチ化単位と表示更新レートの分離点

## Out of Boundary
- Vision推論の実行要否・頻度は扱わない（入力は上流specの結果を利用）
- Motion受信hop・暗転表示切替には触らない
- 判定アルゴリズム（PostureAnalyzer純関数）自体は変更しない

## Upstream / Downstream
- **Upstream**: vision-fps-throttle（hop頻度の上流制約）、vision-face-conditional（検出結果型の前提）、SessionSnapshot構造・MonitorView購読構造
- **Downstream**: dim-mode-saving（isDimmed書込み共有）、Phase G相当の回帰（通知遅延・復帰時間への影響確認）

## Existing Spec Touchpoints
- **Extends**: なし（非機能最適化）
- **Adjacent**: nekoze-fix（§3.3状態表示・§5通知タイミング0.5秒以内・§8ライフサイクルを制約参照）、vision-face-conditional・vision-fps-throttle（captureOutput共有シーム）

## Constraints
- 姿勢判定の継続性維持（UI間引きが判定に波及しない分離設計）
- Swift Concurrencyのactor isolation・データ競合配慮（@MainActor唯一書込み点の原則維持）
- 通知遅延（確定→再生0.5秒以内）・復帰時間の回帰計測、実測なき改善率記載禁止
