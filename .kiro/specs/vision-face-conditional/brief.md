# Brief: vision-face-conditional

## Problem
PoseDetector.detect()がVNDetectFaceRectanglesRequestとVNDetectHumanBodyPoseRequestを毎フレーム無条件で同一perform実行するため、姿勢検出成功フレームでも顔推論コストが発生しバッテリーを消費する。

## Current State
PoseDetector.detect(sampleBuffer:orientation:)は顔→BodyPoseの2リクエストを条件分岐・間引きなしで実行する。顔は全VNFaceObservationから画面中央最小を選択しfaceBoundsのみに使用し、顔のみ検出時は.personOnlyフォールバックを返す。呼び出し元はPostureSessionManager.captureOutput（nonisolated、detectionQueue上で同期実行）である。

## Desired Outcome
人体姿勢が有効な結果を返したフレームでは顔検出を省略し、キーポイント不足時のみ顔検出を実行することで、人物検出セマンティクスを同一に保ちながらVision推論回数を削減する。

## Approach
姿勢優先・顔フォールバックの条件分岐。漸進アプローチの一歩目として純ロジック変更に留め、タイミング・FPS・スレッド構造には触らない。成功・失敗両経路の推論回数を計測して効果検証する。

## Scope
- **In**: 顔検出が人物検出フォールバック用途のみかの全呼出経路確認、姿勢有効時の顔省略設計、キーポイント不足時の顔実行、人物不在/姿勢不明/キャリブレーション/復帰の状態遷移維持、必要に応じたテスト追加
- **Out**: FPS制限・間引き（別spec vision-fps-throttle）、MainActor hop変更（別spec）、顔検出の完全削除、人物検出セマンティクスの変更を伴う仕様変更

## Boundary Candidates
- PoseDetector.detect内のリクエスト実行順序と条件分岐
- .personOnly/.absentの返却セマンティクスとprocessDetection側の扱い

## Out of Boundary
- カメラフレーム取得頻度・推論FPS制御は扱わない
- snapshot更新・UI表示の最適化は扱わない
- Motion・暗転モードには触らない

## Upstream / Downstream
- **Upstream**: nekoze-fix spec §3.4（人物不在警告）・§4（判定・信頼度閾値・近側選択）の人物検出セマンティクス、PoseDetectorTests・PostureSessionManagerTests
- **Downstream**: vision-fps-throttle（間引き後の成功/失敗率に影響）、mainactor-throttle（hop削減の前提条件）、Phase G相当の回帰（顔フォールバック経路）

## Existing Spec Touchpoints
- **Extends**: なし（非機能最適化であり既存機能仕様の変更なし）
- **Adjacent**: nekoze-fix（§3人物検出・§4判定を制約参照）、ios17-baseline（デバイス検証手順を参照）、vision-fps-throttle・mainactor-throttle（captureOutput共有シーム）

## Constraints
- 顔検出の条件付き実行が現在の人物検出ロジックと同じ意味を保つこと（他用途利用があれば削除禁止）
- 姿勢角度・垂直ベクトル・回転/ミラー/aspect fit補正を壊さない
- 成功・失敗両経路の推論回数・推論時間を計測し、実測なき削減率記載禁止
