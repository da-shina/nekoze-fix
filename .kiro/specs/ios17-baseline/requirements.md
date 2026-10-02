# Requirements Document

## Project Description (Input)
NekozeFix の開発者は、デプロイターゲットが 17.0 であるにもかかわらずコードと設計書に残る iOS 16 時代の残滓（非推奨の `AVCaptureVideoOrientation` 系による警告 7 件、自前の向き換算表・フォールバック推定・重複 monitor）に直面している。現状のままでは将来の iOS での削除リスクと横持ち系の不具合温床が残る。Apple 推奨の `AVCaptureDeviceRotationCoordinator` へ全面移行して非推奨警告をゼロにし、向き取得を単一経路化し、既存の振る舞いが変わらないことを全テストと iPad 9th 実機で確認した上で、文書を 17 前提に統一する。

## Boundary Context (Optional)
- **In scope**: 向き取得・適用経路の後継方式への移行、非推奨警告の除去、iOS 17 前提の文書・設定の統一、振る舞い同等性の検証
- **Out of scope**: `@Observable` への移行、Swift 6 厳密並行対応、判定ロジック・閾値・UI 見た目の変更、新機能の追加、電池・性能の数値改善
- **Adjacent expectations**: 猫背判定・代替基準鎖（nekoze-fix 要件 4.x）、回転中の判定停止・再開（同 7.2）、ライフサイクル・自動スリープ（同 8.x）、向き変化時の自動再校正（同 2.3・2.4・7.1）は nekoze-fix spec が所有し、本 spec はその振る舞いを維持することだけを保証する

## Requirements

### Requirement 1: ビルド基盤の iOS 17 前提
**Objective:** As a 開発者, I want 非推奨警告のないクリーンなビルド基盤, so that 将来の iOS での削除リスクがなくなる

#### Acceptance Criteria
1.1. When 開発者がプロジェクトをビルドする, the NekozeFix shall 非推奨 API に関する警告を出さない
1.2. The NekozeFix shall 対応 OS の下限を iOS 17.0 とする

### Requirement 2: 向き追従の一貫性
**Objective:** As a ユーザー, I want デバイスを回転させても映像と姿勢表示が正しく追従すること, so that 縦持ち・横持ちのどちらでも監視できる

#### Acceptance Criteria
2.1. When ユーザーがデバイスを縦置き・横置きのいずれかに構える, the NekozeFix shall カメラ映像の向きを構えた向きに合わせる
2.2. When ユーザーがデバイスを回転させる, the NekozeFix shall 姿勢表示の向きを新しい向きに追従させる
2.3. While デバイスの回転が検出されている, the NekozeFix shall 猫背判定を一時停止する
2.4. When デバイスの回転が完了する, the NekozeFix shall 猫背判定を再開する

### Requirement 3: カメラ切替時の向き継続
**Objective:** As a ユーザー, I want 前面・背面を切り替えても向き追従が正しく続くこと, so that どちらのカメラでも監視できる

#### Acceptance Criteria
3.1. When ユーザーが前面・背面カメラを切り替える, the NekozeFix shall 切り替え後のカメラでも映像の向きを構えた向きに合わせる
3.2. When カメラ切替後に姿勢監視が継続している, the NekozeFix shall 基準線表示の向きを正しく維持する

### Requirement 4: 向き不明時の維持
**Objective:** As a ユーザー, I want 向きが取得できない状況でも監視が継続すること, so that 一時的な条件で監視が中断しない

#### Acceptance Criteria
4.1. While デバイスの向きが不明である, the NekozeFix shall 向き設定を直前の有効な状態に維持する

### Requirement 5: 振る舞い同等性と検証
**Objective:** As a 開発者, I want 既存機能の振る舞いが変わらないことを確認できる, so that 安心して移行できる

#### Acceptance Criteria
5.1. When 本対応の実装が完了する, the NekozeFix shall 全テストスイートに成功する
5.2. The NekozeFix shall 校正から監視・通知、暗転、ライフサイクル、自動再校正の既存動作を維持する
5.3. When 実機で縦置き・横置き・回転遷移・代替表示を確認する, the NekozeFix shall 移行前と同一の振る舞いを示す
