# Brief: nekoze-fix

## Problem
デスクワーカーは長時間のPC作業中に無意識に猫背になりがちである。猫背は首・肩の慢性的な痛み、頭痛、呼吸の浅さなどを引き起こし、長期的には健康問題につながる。現在、手軽にリアルタイムで姿勢を監視し、即座にフィードバックを得られるソリューションが不足している。

## Current State
既存の姿勢矯正アプリは、ウェアラブルセンサーが必要だったり、サブスクリプション課金が高額だったりする。iPhoneのカメラを使ってシンプルに姿勢監視できる無料のネイティブアプリの選択肢が少ない。

## Desired Outcome
iPhoneをデスクに置くだけで、リアルタイムに猫背を検知し、音で即座に通知するシンプルなiOSアプリが完成すること。ユーザーは何も身につけることなく、アプリを開くだけで姿勢改善のサポートを受けられる。

## Approach
**Apple Vision（VNDetectHumanBodyPoseRequest）** を使用する。AVFoundationのフロントカメラパイプラインからフレームを取得し、Vision APIで肩・耳・鼻のキーポイントを検出。耳と肩のY座標の差分が閾値を超えた場合に猫背と判定し、内蔵通知音でアラートを出す。サードパーティ依存なしで、バッテリー効率が最も高く、実装がシンプルなアプローチ。

## Scope
- **In**:
  - フロントカメラによるリアルタイム姿勢検知
  - Apple Vision（VNDetectHumanBodyPoseRequest）によるキーポイント検出
  - 耳ー肩の垂直距離に基づく猫背判定ロジック
  - 内蔵通知音による即時フィードバック
  - 検知の開始/停止UI
  - 感度調整（閾値の変更）
- **Out**:
  - バックグラウンド監視
  - 統計ダッシュボード・履歴記録
  - Android対応
  - 全身骨格推定
  - カスタム通知音の選択
  - クラウド同期・アカウント機能

## Boundary Candidates
- カメラセッション管理（AVFoundation設定・フロントカメラ制御）
- 姿勢検知エンジン（Vision API呼び出し・キーポイント抽出）
- 猫背判定ロジック（耳ー肩垂直距離の計算・閾値判定）
- 通知フィードバック（内蔵音の再生）
- UI（カメラプレビュー・検知状態表示・感度調整コントロール）

## Out of Boundary
- バックグラウンドプロセスでの継続監視
- 姿勢データの永続化・分析
- ユーザーアカウント・設定のクラウド同期
- ヘルスケアアプリとの連携
- ウェアラブルデバイスとの統合

## Upstream / Downstream
- **Upstream**: iOS SDK（AVFoundation, Vision framework）、SwiftUI
- **Downstream**: 将来的な拡張として、統計ダッシュボード、HealthKit連携、Apple Watch連動

## Existing Spec Touchpoints
- **Extends**: なし（新規プロジェクト）
- **Adjacent**: なし

## Constraints
- iOS 16+ が必要（VNDetectHumanBodyPoseRequestはiOS 13+から利用可能だが、SwiftUI Concurrencyや最新APIの活用のためiOS 16を下限とする）
- フロントカメラ必須
- アプリ起動中のみ監視（バックグラウンド監視なし）
- ユーザーはカメラに向かい合って座る前提（横顔・後ろ姿は想定外）
- Apple Visionの信頼度閾値（confidence < 0.5のキーポイントは除外）
