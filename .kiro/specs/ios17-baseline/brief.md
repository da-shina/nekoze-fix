# Brief: ios17-baseline

## Problem
- NekozeFix のデプロイターゲットは 17.0 だが、コードと設計書に iOS 16 時代の残滓がある
- `AVCaptureVideoOrientation` 系（接続の向き設定・UIDevice通知からの換算・フォールバック推定）が iOS 17.0 で非推奨となり、現状 7 件の非推奨警告が出ている
- 向き系は自前換算（device→video マッピング表＋windowScene フォールバック＋5秒タイマ）のため複雑で、14.2 実機検収では横持ち系の不具合が出ている

## Current State
- `IPHONEOS_DEPLOYMENT_TARGET = 17.0`（全構成）。17 専用 API の利用に支障なし
- 非推奨警告 7 件：`CameraSessionManager.swift` 4 件、`DeviceOrientationMonitor.swift` 1 件、`PostureSessionManager.swift` 2 件
- 向き取得は Session 所有の monitor＋UIDevice通知換算に一本化されつつある（MotionService 内蔵 monitor は 14.2 修正で削除済み）。換算表・フォールバック推定・5秒タイマが残存
- 設計書・タスクに「iOS 16+」表記が残存（tech stack、tasks 1.1）。`@available` 分岐は存在しない
- Apple 推奨の後継 `AVCaptureDeviceRotationCoordinator`（preview／capture の horizon-level 回転角、KVO 対応）は未使用。実現可能性の確認済み（Apple 純正・iOS 17+・ライセンス問題なし）

## Desired Outcome
- 非推奨警告ゼロ（`AVCaptureVideoOrientation` への依存を除去）
- 向き取得が RotationCoordinator 中心の単一経路になり、UIDevice通知換算・フォールバック推定・重複 monitor が消える
- 既存の振る舞い（校正→監視→通知、暗転、ライフサイクル、自動再校正、重力基準判定）が変わらないことを全テスト＋iPad 9th 実機で確認する
- 設計書・タスクの 16+ 表記が 17 前提に統一される

## Approach
- **採用案A：RotationCoordinator 全面移行**（ユーザー選択済み）
- preview 用と capture（Vision へ渡す data-output バッファ）用の回転角を coordinator から取得し、接続の `videoRotationAngle` へ適用する
- Session の向き購読を coordinator の KVO に一本化し、`DeviceOrientationMonitor` の videoOrientation 発行と `fromDeviceOrientation` 換算・windowScene フォールバックを削除する（回転中検出の扱いは設計で再定義）
- 棄却案B（警告抑制＋文書整理のみ）：非推奨残置で将来削除リスクと横持ち脆弱性が残るため不採用
- 棄却案C（現行維持＋修正）：複雑さが残り警告も残るため不採用

## Scope
- **In**:
  - RotationCoordinator 導入（カメラ切替時の再生成含む。前面／背面切替に対応）
  - preview 接続・data-output 接続の回転適用の移行（`videoOrientation`→`videoRotationAngle`）
  - 向き購読の一本化と重複 monitor・換算表・フォールバック推定の削除
  - 16+ 表記の 17 前提への統一（design.md tech stack、tasks.md 1.1 等）
  - 振る舞い同等性の全テスト回帰＋iPad 9th 実機確認（縦・横・回転遷移・代替パス）
- **Out**:
  - Observation（`@Observable`）への移行
  - Swift 6 厳密並行対応
  - 判定ロジック・閾値・UI 見た目の変更
  - 新機能の追加

## Boundary Candidates
- 回転角の取得・配信（RotationCoordinator 所有・購読）
- 接続への適用（preview／data-output の回転設定）
- 向き購読側の整理（Session トリガ・自動再校正・なで肩ガイダンス分岐の維持）
- ビルド基盤・文書の 17 前提統一

## Out of Boundary
- 姿勢判定アルゴリズム（PostureAnalyzer／resolve／OR 判定）の変更
- `@Observable` 移行・Swift 6 対応などの近代化全般
- 電池・性能の数値改善（回帰確認のみ）

## Upstream / Downstream
- **Upstream**: nekoze-fix spec（要件 7.1 向き対応、8.x ライフサイクル、4.x 判定表示。振る舞いを変えないことが制約）
- **Downstream**: 将来の近代化 spec（Observation 移行等）の前提になる

## Existing Spec Touchpoints
- **Extends**: なし（nekoze-fix の振る舞いは変えない。設計書の Technology Stack・向き関連記述の更新は本 spec の所有）
- **Adjacent**: nekoze-fix（13.3 自動再校正、13.2 基準線表示、DeviceOrientationMonitor の回転中表示抑制。境界の重なりはレビューで監視）

## Constraints
- デプロイターゲット 17.0 を前提とし、`@available` 分岐は追加しない
- 振る舞い変更なし（UIDevice通知→KVO への切替によるタイミング差は、既存の 0.5 秒ホールド・自動再校正・校正不安定リセットの範囲で吸収できることを検証する）
- 実機検証は iPad 9th（手持ちあり）で行う。シミュレータでは代替パスのみ検証可能
- 注意：coordinator の角度通知は UIDevice 通知より遅延する場合がある（報告例で約1秒）。遷移過渡の扱いを設計で明示する
