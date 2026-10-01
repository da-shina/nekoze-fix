# Research: ios17-baseline 実装ギャップ分析

## 現状調査

### 向き関連アセット
- `NekozeFix/Services/CameraSessionManager.swift` — `fromDeviceOrientation` 換算（device→video マッピング表＋windowScene フォールバック）、data-output 接続の `videoOrientation` 設定・前面ミラー設定
- `NekozeFix/Services/DeviceOrientationMonitor.swift` — UIDevice通知購読、`currentVideoOrientation` 発行、`isRotating`＋5秒タイマ
- `NekozeFix/Session/PostureSessionManager.swift` — monitor 購読→`handleVideoOrientationChange`（data接続向き更新、`isLandscape` 唯一の書込み点、monitoring時のみ自動再校正）。`videoAspectRatio` はフレーム実測で更新
- `NekozeFix/UI/CameraPreviewView.swift` — preview接続の向き更新（UIDevice直接参照＋windowSceneフォールバック）
- `NekozeFix/Types/PostureTypes.swift` — `isLandscape`（なで肩ガイダンス分岐用）、`.rotating` phase値
- 非推奨警告 7 件（上記3ファイル）。デプロイターゲットは全構成 17.0。`@available` 分岐なし

### 既存パターン・制約
- 依存方向 Types → Domain → Services → Session → UI。Domain は Services 非参照
- テストは XCTest＋合成フレーム注入シーム（155件全成功）。向き系テスト：`OrientationRecalibrationTests`、`ShoulderMissingGuidanceTests`
- iPadOS 18 以降、data-output バッファは接続向きに自動回転して配信される（Session内コメント）。Vision には常に `.up`
- 14.2 修正で MotionService は向き非依存（`K=normalize(−gx,−gy)`）となり向きを持たない

### 奇妙な残存（設計で扱うこと）
- `.rotating` phase値は読まれるが書かれない（設定箇所なし）。`isRotating` の購読者も Session にはいない
- `isLandscape` の唯一の書込み点は Session の向きハンドラ
- 16+ 表記残存：design.md tech stack、tasks.md 1.1

## 要件-資産マップ

| 要件 | 現状資産 | ギャップ |
|---|---|---|
| Req 1 警告ゼロ・下限17.0 | 警告7件、target 17.0済み | Missing: 後継APIへの移行 |
| Req 2 向き追従の一貫性 | 二重の向き取得（monitor＋preview直読）、換算表 | Constraint: 経路統合時に回転過渡の扱いを再定義する必要あり |
| Req 3 カメラ切替時の継続 | 切替UI・再構成あり、coordinatorなし | Missing: カメラ毎の coordinator 再生成 |
| Req 4 向き不明時の維持 | 不明時早期 return で前値維持 | 既存動作の温存（小） |
| Req 5 振る舞い同等性 | 全155テスト＋iPad 9th実機レーン | 既存検証基盤あり |

## 実装アプローチの選択肢

### Option A: 既存拡張（最小）
- 非推奨箇所だけ `videoRotationAngle` 直置換し、UIDevice通知・換算表・monitor 構成は維持する
- ✅ 差分最小、短期間。❌ 警告は消えるが二重経路・5秒タイマ・フォールバック推定の複雑さが残る。回転角の一貫性（preview／capture）は自前管理のまま

### Option B: 新規集約（推奨の方向性）
- `RotationCoordinator` を所有する向きサービスを新設し、preview／data-output 両接続の回転適用と Session への向き通知を一本化する。`fromDeviceOrientation`・windowSceneフォールバック・重複購読を削除する
- ✅ 単一経路、Apple推奨、横持ち系の根本対策。❌ 既存テスト（向き購読・再校正トリガ）の更新が必須。KVO タイミング差（報告例で約1秒遅延）の吸収設計が必要

### Option C: ハイブリッド（段階移行）
- 先に preview 接続だけ移行して実機確認し、次に data-output 接続と購読一本化へ進む
- ✅ リスク分散、各段階で実機検証可能。❌ 移行期間中は新旧が混在し、一時的に複雑さが増す

## 工数・リスク
- Effort: M（3〜7日）。理由：3ファイル＋テスト更新＋実機検証を含むが、新規機能なし
- Risk: Medium。理由：API自体は枯れた純正だが、KVOタイミング差と回転過渡の吸収可否が実機検証まで確定しない

## 設計への申送り
- 推奨：Option B（単一経路化）。段階確認が要る場合は C の順序をタスク分割に反映
- 設計で決めること：回転過渡（一時停止・再開）の再定義、`.rotating`／`isRotating` の存廃、`isLandscape` 書込み点の移管先、カメラ切替時の coordinator 再生成点、data-output 接続の回転適用方式（接続設定 vs 表示側回転。Vision へ渡すバッファの向きが `.up` 前提を保つこと）
- Research Needed:
  - `videoRotationAngle` 対応可否の実行時判定（`isVideoRotationAngleSupported`）と非対応時の退行則
  - coordinator 角度通知の遅延実測（9th 実機。UIDevice通知との差）
  - data-output 接続の回転変更に伴うフレーム配送途切れの有無と影響

---

## 設計Discovery・Synthesis記録（/kiro-spec-design）

### Discovery種別
- light（Extension）。参照スキル：kiro-spec-design の design-discovery-light、design-principles、design-synthesis

### 統合点調査の要点
- 向き値の消費点：Session の `handleVideoOrientationChange`（data接続更新・`isLandscape` 書込み・自動再校正）、preview の `updatePreviewOrientation`、テストの直接呼出し（`OrientationRecalibrationTests`）
- `.rotating` phase値は設定箇所なし、`isRotating` の Session 側購読なし。回転過渡の一時停止は実質 13.3 自動再校正（監視停止→再校正完了で復帰）が担っている
- `videoAspectRatio` はフレーム実測で更新されており向き換算と独立。本 spec は触らない

### Synthesis
- Generalization：要件 2（追従）・3（切替継続）・4（不明時維持）は「デバイス姿勢の単一信頼源」の変形。回転角（preview／capture）と変更通知を出す単一サービスに集約し、実装範囲は現行要件に限定する
- Build vs Adopt：回転角取得は Apple 純正 `AVCaptureDeviceRotationCoordinator`（iOS 17+、保守中、ライセンス問題なし）を採用。自前換算の維持は棄却（非推奨残置＋横持ち脆弱性）
- Simplification：`fromDeviceOrientation` 換算表・windowScene フォールバック・5秒タイマ・重複 monitor を削除。`.rotating`／`isRotating` の死経路は除去し、過渡停止は自動再校正経路に一本化する（振る舞い不変）

### Design Decisions
- 新設 `DeviceRotationService`（Services）が coordinator を所有し、カメラ切替時に再生成する。Session は変更通知を購読し、接続への適用は `CameraSessionManager` 経由で行う（依存方向 Types → Domain → Services → Session → UI を維持）
- data-output バッファの向きは接続の回転設定で維持し、Vision への `.up` 固定は変えない
- KVO 通知遅延（報告例で約1秒）は既存の 0.5 秒ホールド・校正不安定リセット・自動再校正で吸収することを検証条件にする
