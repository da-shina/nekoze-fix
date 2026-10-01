# 実機検証記録 — ios17-baseline Task 5.2

- 日時: 2026-10-01 (JST)
- 対象デバイス: iPad (9th generation) (iPad12,1)、destination `platform=iOS,name=9th`
- デバイス状態: `xcrun devicectl list devices` で `available (paired)` を確認してから実行
- コード署名: 成功（既存の `Apple Development: shinada.atsushi@gmail.com` 署名・Team Provisioning Profile で問題なし）
- Simulator ベースライン (Task 5.1): 209 tests / 0 failures、非推奨警告 15→0

## 1. 自動実行結果（実機 `xcodebuild test`）

### 1.1 ビルド
- `xcodebuild -destination 'platform=iOS,name=9th' build` → **BUILD SUCCEEDED**

### 1.2 フルテスト（実機初実行）
- Run A: 209 tests / 2 failures（失敗は MotionUsageDescriptionTests の2件のみ）
- Run B: 209 tests / 5 failures（上記2件 ＋ DistanceMetricIntegrationTests 2件＝3 failures表記、内1テストが重複カウント）
- 単独再実行 `DistanceMetricIntegrationTests`: 5 tests / 1 failure（失敗箇所が Run B と異なる）
- → DistanceMetric の失敗箇所は実行ごとに変動する。タイミング依存の flaky であり、本 spec の回転角変更とは無関係（姿勢判定・距離指標のテスト。simulator では green）。

### 1.3 回転角関連スイート（本 spec の守備範囲）— 全 PASS
| Suite | 結果（実機） |
|---|---|
| DeviceRotationServiceTests | 4/4 passed（HW-gated 3件が実機で初実行） |
| RotationAngleInjectionTests | 9/9 passed（device-coupled 2件が実機で初実行） |
| CameraSessionManagerRotationTests | passed |
| CameraPreviewRotationTests | passed |
| OrientationRecalibrationTests | 5/5 passed |
| RotationWiringOrderTests | passed |
| SessionRotationTriggerTests | passed |

### 1.4 既知の実機固有失敗（本 spec 範囲外・合否判定から除外、理由付き）
- `MotionUsageDescriptionTests.testProjectDeclaresMotionKeyForGeneratedPlist`／`testSourceInfoPlistContainsMotionWording`:
  FAIL（実機のみ。simulator では pass）。
  原因はテスト機構: `repoFileURL` が `#filePath`（テストバイナリに焼き込まれた Mac ホストのパス）で
  リポジトリ実ファイルを探すが、iPad 上にそのパスは存在しないため `XCTUnwrap failed: expected non-nil value of type "URL"`。
  実振る舞いを検証する `testMotionUsageDescriptionIsPresentInBuiltBundle`（built app の Info.plist キー確認）は
  実機でも PASS。nekoze-fix 側タスク 11.2 の所有であり、本 spec の変更対象外。
- `DistanceMetricIntegrationTests`（変動）: タイミング依存 flaky（上記 1.2）。本 spec 範囲外。

## 2. 項目別判定（design.md Testing Strategy + task text の5項目）

### 項目1: 縦・横・回転遷移・代替表示の動作（Req 2.1, 2.2, 4.1）→ MANUAL（未実施）
### 項目2: KVO通知遅延の実測と吸収可否（Req 2.3, 2.4）→ MANUAL（未実施）
- なお自動側の裏付け: `OrientationRecalibrationTests.testMonitoringCaptureAngleChange_discardsReferencesAndMovesToCalibrating`
  が実機で PASS（3.1秒。角度変化→自動再校正遷移の結合経路が実機で動作することの証明。ただし注入角であり KVO 実遅延の実測ではない）。
- 合否基準（暫定値）: 回転→自動再校正発火まで2秒以内。
### 項目3: フレーム途切れ有無（design Risks）→ MANUAL（未実施）
- 自動テストで data-output 回転角変更時のフレーム配送途切れを観測するものは存在しない。
### 項目4: 前面／背面の両経路（Req 3.1, 3.2）→ 自動で PASS
- `DeviceRotationServiceTests.testRecreateAdoptsNewDeviceCoordinatorAngles` が実機で PASS。
  本テストは front・back 両 video デバイスの存在を guard 条件としており、実行されたこと自体が
  iPad 9th が両カメラを持ち、切替再生成が両経路で動作することの証明。
- `RotationAngleInjectionTests.testRecreateSwitchesDeviceWhenHardwareExists`（front→back 切替）も実機で PASS。
### 項目5: 移行前と同一振る舞いの合否 → 条件付き合否（下記「総合判定」参照）

## 3. MANUAL チェックリスト（人手で実施すること）
- [x] MANUAL-1（縦・横・代替表示）: iPad 9th にアプリを起動し、縦持ちで監視開始→カメラ映像と姿勢表示が縦向きに一致することを目視。横持ち（左右両方向）に構え直し→映像・表示が追従することを目視。代替表示（人物不在・肩欠落等のガイダンス文言）が出る条件で向きが維持されることを目視。合否＝移行前と同一の見た目・文言であること。
  - 結果（2026-10-02）: PASS。ポートレート・左右ランドスケープの3方向で緑線が画面上向きを確認（(θ−90°)修正の再デプロイ後に目視）。
- [x] MANUAL-2（回転遷移・再校正2秒）: 監視中に iPad を縦→横へ回転させ、自動再校正が発火すること（校正中表示への遷移）を確認。合否基準＝回転開始から自動再校正発火まで2秒以内（暫定値）。ストップウォッチで計測し実測値を記録すること。
  - 結果（2026-10-02）: PASS（所有者による実測確認）。
- [x] MANUAL-3（KVO遅延吸収）: MANUAL-2 の回転操作で、表示の追従遅れが体感で吸収されていること（0.5秒ホールド＋自動再校正で約1秒級の遅延を吸収する設計想定）。UIDevice通知との差の厳密測定は不要。合否＝MANUAL-2 の2秒基準を満たすこと。
  - 結果（2026-10-02）: PASS（所有者による体感確認）。
- [ ] MANUAL-4（フレーム途切れ）: 回転前後および回転中のプレビュー映像に途切れ・固まりがないことを目視。前面・背面の両カメラで実施。合否＝途切れなし。
- [ ] MANUAL-5（前面／背面の目視）: カメラ切替操作を行い、切替後の映像向きが構えた向きに合っていること、基準線表示の向きが維持されることを目視（縦・横の各姿勢で）。

## 4. 総合判定
- 自動検証の範囲: **PASS** — 回転角関連全スイートが実機初実行で green。前面／背面の両経路（項目4）は実機証明済み。
- 実機検証全体の合否: **MANUAL 残あり（MANUAL-4・5 が未実施。MANUAL-1〜3 は2026-10-02にPASS）** — 上記チェックリストの人手実施と記録をもって Task 5.2 完了とする。
  自動テストだけでは Task 5.2 の完了条件（実機検証記録が出揃い、移行前と同一振る舞いの合否が判定できる）を満たさない。
- 本 spec の生産コード変更に起因する実機退行: なし（実機失敗はすべて範囲外・環境起因。1.4 参照）。
