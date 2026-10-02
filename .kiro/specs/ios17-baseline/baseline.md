# ベースライン記録（移行前・タスク 1.1）

移行後の比較基準（タスク 5.1 の合否判定用）。測定はすべて本ファイル記載のコマンドで行った。

- 記録日: 2026-10-01
- git HEAD: `334b4b8 fix(nekoze-fix): orientation-independent gravity mapping for reference vector`
- 作業ツリー状態: nekoze-fix spec 側の未コミット変更あり（design.md / spec.json / tasks.md / CONTEXT.md）。アプリソース（NekozeFix/・NekozeFixTests/）に未コミット変更なし
- 実行環境: Xcode（`xcrun simctl list devices` に iOS 26.5 の `iPhone 17 Pro` あり）。destination は `platform=iOS Simulator,name=iPhone 17 Pro` を使用
- デプロイターゲット: `IPHONEOS_DEPLOYMENT_TARGET = 17.0`（全 6 構成で確認。要件 1.2 は移行前から満たしている）

## 非推奨警告（要件 1.1 の比較基準）

- ビルド結果: `** BUILD SUCCEEDED **`（exit=0）
- 再現コマンド（フルログを保存して集計すること。`tail` では警告行が欠落する）:
  - `xcodebuild -project NekozeFix.xcodeproj -scheme NekozeFix -destination 'platform=iOS Simulator,name=iPhone 17 Pro' clean build > build.log 2>&1`
  - 集計: `grep "warning:.*deprecated in iOS 17.0" build.log | sed -E 's|.*/NekozeFix/([^:]+:[0-9]+:[0-9]+): warning: (.*)|\1 :: \2|' | sort -u`
  - 注意: 同一警告がログ内に重複出力される（25 行）ため、ファイル:行:列＋メッセージで重複除去して数えること
- `deprecated in iOS 17.0` の distinct 箇所数: **16 件**
  - うち `AVCaptureVideoOrientation` / `videoOrientation` / `isVideoOrientationSupported` 系: **15 件**
  - うち `onChange(of:perform:)` 系（RootView.swift:37:10、本 spec の範囲外）: **1 件**

### ファイル別内訳（AVCapture 系 15 件）

| ファイル | 件数 | 行 |
|---|---|---|
| NekozeFix/Services/CameraSessionManager.swift | 9 | 4:11, 6:115, 14:20, 34:48, 38:31, 39:32, 114:53, 173:31, 174:32 |
| NekozeFix/Services/DeviceOrientationMonitor.swift | 2 | 10:58, 85:36 |
| NekozeFix/Session/PostureSessionManager.swift | 2 | 104:44, 113:54 |
| NekozeFix/UI/CameraPreviewView.swift | 2 | 71:26, 72:20 |

- 上記以外の警告（移行完了条件には含めない。参考値）: AccentColor 未使用 1 件、AppIntents メタデータ抽出スキップ 1 件
- research.md / brief.md の「警告 7 件（CameraSessionManager 4 / DeviceOrientationMonitor 1 / PostureSessionManager 2）」という記述は本記録時点の実測と一致しない。実測は AVCapture 系だけで 15 件あり、CameraPreviewView の 2 件も含まれる。移行完了条件（タスク 5.1）の「警告ゼロ」は本記録の **AVCapture 系 15 件がゼロになること**を基準とする

## 全テスト結果（要件 5.1 の比較基準）

- テスト結果: `** TEST SUCCEEDED **`（exit=0）、失敗 0 件
- 実行コマンド: `xcodebuild -project NekozeFix.xcodeproj -scheme NekozeFix -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`
- 実績: テストケース **156 件成功 / 0 件失敗**（16 スイート）。フルログの `Test case ... passed on` 行を計数
  - 集計: `grep -c "Test case .* passed on" test.log`＝156、`grep -c "Test case .* failed on" test.log`＝0
- research.md の「155 件全成功」という記述は本記録時点の実測（156 件）と一致しない。移行後の比較基準は **156 件成功 / 0 件失敗**とする

## 移行後の比較基準（タスク 5.1 への申送り）

1. 同一コマンドのクリーンビルドで上記 AVCapture 系 15 件の警告がゼロになること（RootView の `onChange` 1 件は本 spec の範囲外のため完了条件に含めない）
2. 同一コマンドのフルテストで `** TEST SUCCEEDED **` かつ 156 件成功 / 0 件失敗を維持すること
