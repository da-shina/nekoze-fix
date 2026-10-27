# 実機 E2E テストと性能計測（task 11）

本記録は Requirement 5（5.1, 5.2, 5.3, 5.4）および Requirement 2.2 に対応する、
通常/暗転の長時間不在における視覚処理量の実測記録である。
形式は `dim-mode-saving/design.md`「実測記録の正準雛形（4spec共通の集約先）」に従う。

## 測定環境と制約

- 測定は実機で実施した。端末は iPhone 13 mini（iPhone14,4）、iOS 18.7.7、
  bundle identifier `com.nekoze.nekoze-fix`。
- 計測手段は `xcrun devicectl device process launch --console` によるアプリ標準出力の中継。
  5秒窓の `[NekozeFix Metrics]` ログから、`faceThrottled` / `faceExecuted` /
  `faceSkipped` / `faceTotalTime` / `poseTotalTime` / `limitFPS` / `motionFreq` /
  `judge` を取得した。
- 制約（暗転中のログ停止）: 製品コードの `enterDimMode()` は `stopMetricsLogging()` を呼ぶため、
  暗転中の値は通常のログには出力されない。観測のため、計測専用の一時配線
  （`enterDimMode` 内の `stopMetricsLogging()` 呼び出しを一時無効化）を用いた。
  また、`faceTotalTime` / `poseTotalTime` は通常のログ出力に含まれないため、
  計測専用に同2項目を出力へ一時追加した。いずれの配線も計測後に `git checkout` で復元し、
  コミットしていない（作業ツリーはクリーン、復元後のビルドは BUILD SUCCEEDED）。
  したがって暗転・長時間不在の段階観測値は、この一時配線下で取得した値である。
- 本記録の視覚処理量は上記の一時配線下の計測値であり、製品ビルドの電力特性とは独立に扱う。
- 電力の計測手段（ADR-0025）: Xcode Energy Report（Average Energy Impact ゲージ評価＋
  Average Component Utilization の領域別%）。本機は iOS 18.7.7 であり、
  `xctrace` の Power Profiler は iOS 26.0 以上を要求するため取得できない。
  Xcode GUI の Energy Report は本セッションでは未取得のため、電力は全条件「未計測」とする。
- 復帰時間は「復帰直後」条件のみ5秒窓ログで確認した（他の条件は復帰を伴わない）。検出精度（TP/FP/FN）の
  定量計測は本セッションでは未実施のため、未計測とする。
- 単体・結合テストの成功は機能的正確性の証拠であり、電力・実機検出精度の
  実測値とはみなさない。復帰時間は「復帰直後」条件の5秒窓ログによる確認に留める。
- 実測していない省電力率・持続時間の推定値・換算値は本記録に含めない（5.3）。
- 測定できない項目は未計測として明記する（5.3）。
- 本記録の実測は、`PoseDetector` の間引き判定を `evaluateFaceFallbackGate(now:tracker:)`
  へ抽出する前（一時配線下）に取得した値である。抽出後の実推論経路での再確認は未実施であり、
  本記録を変更後の経路の確認済み証拠とはみなさない。実機確認時に対象コミットと結果を追記する。

## セッション情報

```text
セッションID: セッション1（視覚処理量）
計測日時: 2026-10-25 17:49:49〜17:59:05（約9分16秒、連続）
端末 / OS: iPhone 13 mini（iPhone14,4） / iOS 18.7.7
計測手段: devicectl console 中継による [NekozeFix Metrics] 5秒窓ログ
            （暗転中ログ継続＋faceTotalTime/poseTotalTime 出力の一時配線下）
姿勢・背景条件: 在席条件は椅子上でカメラ正面、不在条件は視界外へ退出
```

## 条件別記録

### 条件: 通常モード在席

```text
条件: 通常モード在席（17:50:52〜17:52:22、18窓）
電力: 未計測（iOS 18.7.7 のため xctrace Power Profiler 不可。Xcode GUI Energy Report は本セッション未取得）
復帰時間: 未計測（本条件は復帰を伴わない）
精度: 未計測（実機での検出精度計測は未実施のため）
比較根拠: 間引きなしの基準条件。
  定常窓の実測: limitFPS=15.0, motionFreq=15Hz, faceThrottled=0。
  faceExecuted は 1〜56 回/5秒窓、faceTotalTime は 0.026〜1.326 s/5秒窓、
  poseTotalTime は約1.0 s/5秒窓。judge は g/s/p（例 g3/s2/p56）。
  機能ピン（実測値ではなく機能的正確性の証拠）: 通常段階の上限・頻度と判定意味不変は既存テストで green。
```

### 条件: 通常モード長時間不在

```text
条件: 通常モード長時間不在（17:52:26〜17:54:36、26窓。しきい値60秒経過後の定常8窓を評価）
電力: 未計測（同上）
復帰時間: 未計測（復帰は「復帰直後」に記載）
精度: 未計測（実機での検出精度計測は未実施のため）
比較根拠: 間引きの主要効果を確認。
  定常窓の実測（17:54:00〜17:54:35 の8窓）: limitFPS=15.0, motionFreq=15Hz, judge=a62〜a63。
  faceThrottled は 61〜62 回/5秒窓（間引きスキップ）、faceExecuted は 1 回/5秒窓
  （5秒間隔に制限）、faceTotalTime は 0.017 s/5秒窓、poseTotalTime は約0.98 s/5秒窓。
  不在中に顔フォールバックが毎推論から5秒間隔へ低減したことを実測確認。
  機能ピン: ProlongedAbsenceTrackerTests / ProlongedAbsenceIntegrationTests が green。
```

### 条件: 暗転段階（在席）

```text
条件: 暗転段階（在席）（17:55:16〜17:56:51、19窓。暗転投入後）
電力: 未計測（同上）
復帰時間: 未計測（本条件は復帰を伴わない）
精度: 未計測（実機での検出精度計測は未実施のため）
比較根拠: 暗転長時間不在との比較基準。
  定常窓の実測: limitFPS=10.0, motionFreq=15Hz, faceThrottled=0（累積値は885で不変）。
  faceExecuted は 19〜40 回/5秒窓、faceTotalTime は 0.489〜0.902 s/5秒窓、
  poseTotalTime は約0.73 s/5秒窓。judge は g/p（例 g9/s0/p33）。
  機能ピン: DimPowerPolicyTests / FrameThrottleTests / PostureSessionManagerTests が green。
```

### 条件: 暗転モード長時間不在

```text
条件: 暗転モード長時間不在（17:56:55〜17:59:05、27窓。しきい値60秒経過後の定常8窓を評価）
電力: 未計測（同上）
復帰時間: 未計測（復帰は「復帰直後」に記載）
精度: 未計測（実機での検出精度計測は未実施のため）
比較根拠: 暗転段階（在席）より視覚処理量が低いことを実測確認（Req 2.2 / 5.1）。
  定常窓の実測（17:58:30〜17:59:05 の8窓）: limitFPS=10.0, motionFreq=10Hz, judge=a41〜a42。
  faceThrottled は 40〜41 回/5秒窓、faceExecuted は 1 回/5秒窓、
  faceTotalTime は 0.017〜0.019 s/5秒窓、poseTotalTime は約0.65 s/5秒窓。
  暗転段階（在席）との比較: faceExecuted 19〜40 → 1 回/5秒窓、
  faceTotalTime 0.489〜0.902 → 0.017〜0.019 s/5秒窓、poseTotalTime 約0.73 → 約0.65 s/5秒窓。
  間引き間隔は通常/暗転で同一の5秒であり、暗転中も有効であることを確認。
```

### 条件: 復帰直後

```text
条件: 復帰直後（17:54:41〜17:55:11、通常モードでの復帰）
電力: 未計測（同上）
復帰時間: 5秒以内（5秒窓ログで確認。最終不在窓 17:54:45 は judge=a62、
          次窓 17:54:50 で judge=a1 となり在席判定へ復帰。間引き間隔5秒以内）
精度: 未計測（実機での検出精度計測は未実施のため）
比較根拠: 復帰で faceThrottled が 885 で停止し、faceExecuted が再開（1744→1751→1758）。
  judge が a から g/s/p へ復帰。間引き間隔5秒以内での復帰検出を確認（Req 5.4）。
  機能ピン: 復帰経路（人物再検出・暗転解除）のテストが green。
```

### 条件: 長時間監視

```text
条件: 長時間監視
電力: 未計測（同上）
復帰時間: 未計測
精度: 未計測
比較根拠: 本セッションは約9分16秒の連続監視で、クラッシュ・明示的エラーは観測されなかったが、
  task 11 が求める長時間監視の継続時間には達していないため「未計測」とする。
  メモリリークの定量評価（Instruments 等）は未実施。
```

## 暗転モード長時間不在と暗転段階（在席）の比較（Req 2.2 / 5.1）

- 同一セッション・同一端末・同一計測手段（5秒窓ログ）での実測比較:
  - 暗転段階（在席）: limitFPS=10.0 / motionFreq=15Hz / faceExecuted 19〜40 回/5秒窓 /
    faceTotalTime 0.489〜0.902 s/5秒窓 / poseTotalTime 約0.73 s/5秒窓 / faceThrottled=0
  - 暗転モード長時間不在: limitFPS=10.0 / motionFreq=10Hz / faceExecuted 1 回/5秒窓 /
    faceTotalTime 0.017〜0.019 s/5秒窓 / poseTotalTime 約0.65 s/5秒窓 / faceThrottled 40〜41 回/5秒窓
- 判定: 暗転モード長時間不在では、暗転段階（在席）より faceExecuted・faceTotalTime が
  大きく低下し（約 95% 以上減、窓あたり比較）、poseTotalTime も微減した。
  暗転中の間引きが視覚処理量を低減することを実測で確認する（Req 2.2 / 5.1）。
- 通常モード長時間不在でも、通常モード在席の faceExecuted（最大56回/5秒窓）に対し
  1回/5秒窓まで低減することを確認した（Req 5.2）。

## 未計測・部分記録の扱い

- 電力（全条件）: 未計測。iOS 18.7.7 では `xctrace` Power Profiler が使えず、
  Xcode GUI Energy Report は本セッションで取得していない。推定値・換算値は記載しない。
- 長時間監視: 未計測（約9分16秒の連続監視でクラッシュなしを観測したが、要求継続時間に未達）。
- 復帰時間: 5秒以内を5秒窓ログで確認（定量のミリ秒精度は未計測）。
- 検出精度（TP/FP/FN）: 未計測。

## 参照

- `.kiro/specs/absent-vision-reduction/requirements.md` Requirement 2.2, 5.1–5.4
- `.kiro/specs/absent-vision-reduction/design.md` Session / Metrics 計測、Testing Strategy
- `.kiro/specs/dim-mode-saving/design.md`「実測記録の正準雛形（4spec共通の集約先）」
- `docs/adr/0025-energy-impact-as-power-measurement.md`
- `docs/adr/0026-face-fallback-throttling.md`
- 実測ログ: `measurements/raw/absent-vision-final-session.log`
- 条件マーカー: `measurements/raw/markers.txt`
