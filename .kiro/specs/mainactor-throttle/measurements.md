# 実機計測記録: mainactor-throttle (タスク 4.3)

## 計測環境

| 項目 | 値 |
|------|-----|
| デバイス | iPhone 13 mini (iPhone14,4、mini) |
| iOS バージョン | 18.7.7 (22H340、devicectl取得) |
| アプリバージョン | NekozeFix (feature/mainactor-throttle @cde0414、Debug-iphoneos) |
| カメラ位置 | 前面カメラ (フロント) |
| セッションプリセット | VGA 640×480 (4:3) |
| 計測日時 | 2026-10-14 20:52〜21:18 (約26分、中継連続) |
| 計測者 | 手動シナリオ操作 + エージェントがログ中継・保存 |
| 取得方法 | `devicectl device process launch --device mini --terminate-existing --console com.nekoze.nekoze-fix` の標準出力中継（方法B変形）。Xcodeコンソールと同一の `print("[NekozeFix Metrics]...")` 系列 |

## ログ形式

```
[NekozeFix Metrics] arrivals=... inferences=... drops=... totalInferenceTime=...s inputFPS=... inferFPS=... avgInferTime=...s dropRate=...% residual=...s limitFPS=15.0 hopSubmits=... hopDelivers=... hopCoalesced=... hopLastWait=...s
```

- `hopSubmits/hopDelivers/hopCoalesced`: Main受け渡しゲートの申請・配送・集約数（区間累積。停止・再開でリセット、系列で追跡）
- `hopLastWait`: 初回集約→排出の待ち時間（最長待ち。定常で約0.08秒＝表示間隔0.1秒と整合）
- 既知現象: 約25〜50秒ごとに計数区間が再開始する（arrivals急減。カメラ再起動・計測窓再開のいずれか。fps-throttle計測でも同一現象を確認済み）

## シナリオ別計測記録（mini）

> 各値は区間内最終点の抜粋。Sequencesは `/tmp/nekoze-measure/` に保存（01-normal〜06-long）。

| シナリオ | 取得点数 | inputFPS | inferFPS | avgInferTime | dropRate | hopSubmits | hopDelivers | hopCoalesced | 集約率 | hopLastWait | 備考 |
|----------|---------|----------|----------|--------------|----------|------------|-------------|--------------|--------|-------------|------|
| 通常（良好静止） | 14点・約70秒 | 24.80 | 12.40 | 0.0167s | 50.00% | 372 | 220 | 152 | 40.9% | 0.0823s | ゲート正常動作 |
| 猫背（意図的猫背） | 15点・約75秒 | 24.84 | 12.42 | 0.0165s | 50.00% | 683 | 376 | 307 | 44.9% | 0.0833s | 区間リセット1回あり |
| 不在（レンズ遮蔽/離席） | 8点・約40秒 | 24.82 | 12.42 | 0.0316s | 49.95% | 496 | 485 | 11 | 2.2% | 0.1049s | 不在系は遷移強制でほぼ全量配送（設計通り）。avgInferTime上昇は人物不在系検出経路 |
| 復帰（不在→着席×3） | 6点・約30秒 | 24.83 | 12.43 | 0.0237s | 49.93% | 373 | 292 | 81 | 21.7% | 0.0810s | 集約が再開し定常へ復帰 |
| 暗転（暗転維持+解除） | 9点・約45秒 | 24.85 | 12.45 | 0.0165s | 49.90% | 497 | 281 | 216 | 43.5% | 0.0744s | 安定動作。解除後即時認識（体感） |
| 長時間（10分連続） | 125点・約625秒 | 24.90 | 12.45 | 0.0166s | 50.00% | 7781 | 4038 | 3743 | 48.1% | 0.0800s | 単一区間で625秒連続。フリーズ・古び表示・停止なし |

### 長時間の安定性

- 開始→終了まで単一計数区間で完走（arrivals 0→15562、リセットなし）
- `hopDelivers/経過秒 ≒ 6.5Hz`（4038/625秒）。表示間隔0.1秒（10Hz）に対し遷移・校正の影響でやや下振れするが、集約率48%でMain投入を約半減
- `hopLastWait` は全区間 0.07〜0.10秒で安定。表示の古び・停止の目視報告なし

## 通知遅延・復帰時間（Req 5.2）

| 項目 | 結果 | 根拠 |
|------|------|------|
| 猫背確定→再生0.5秒以内 | **合格（0.3秒以内×3回）** | 画面収録（音声あり）の差分算出。3回いずれも0.3秒以内でNFR 8.2（0.5秒以内）を満たす |
| 復帰時間（不在→着席×3） | 定量未計測・体感1秒以下の瞬時復帰 | ストップウォッチなしの体感。定量値としての記載はしない |
| 暗転解除後復帰 | 定量未計測・すぐさま認識開始を体感 | 同上 |

## CPU使用率（Req 7.1の一部）

| シナリオ | CPU平均 | CPUピーク | 計測方法 |
|----------|--------|----------|----------|
| 通常 | 20〜24% | 未計測 | Xcode Debug Navigator目視（mini実機・Xcode Run接続） |
| 長時間 | 22% | 未計測 | 同上 |
| 暗転 | 20〜22% | 未計測 | 同上 |
| 不在 | 38〜40% | 未計測 | 同上。不在系検出経路のため高め（avgInferTime上昇と整合） |

## 未計測項目（Req 7.2/7.3対応）

以下の項目は **実測していない** ため、効果として記載しない：

| 項目 | 未計測理由 | 今後の計測予定 |
|------|------------|----------------|
| 確定→再生の定量遅延 | 計測済み（0.3秒以内×3回、合格） | — |
| 復帰時間の定量値 | ストップウォッチ計測なし | 次回計測で3件の秒数を記録する |
| CPU平均・ピーク | 平均は計測済み（通常20〜24%・長時間22%・暗転20〜22%・不在38〜40%）。ピークは未計測 | ピークはInstruments等で別途取得する |
| 省電力率・持続時間延長 | 長時間電力計測なし | 実測なしのため記載しない（推定禁止） |
| 真のキュー待ち時間 | 待機列を持たない設計のため計測不可 | N/A（`hopLastWait`＝初回集約〜排出を記録） |

## 計測ログ抜粋

### 通常・最終点
```
[NekozeFix Metrics] arrivals=744 inferences=372 drops=372 totalInferenceTime=6.2113s inputFPS=24.80 inferFPS=12.40 avgInferTime=0.0167s dropRate=50.00% residual=0.0640s limitFPS=15.0 hopSubmits=372 hopDelivers=220 hopCoalesced=152 hopLastWait=0.0823s
```

### 不在・最終点（全量配送の例）
```
[NekozeFix Metrics] arrivals=993 inferences=497 drops=496 totalInferenceTime=15.6990s inputFPS=24.82 inferFPS=12.42 avgInferTime=0.0316s dropRate=49.95% residual=0.0489s limitFPS=15.0 hopSubmits=496 hopDelivers=485 hopCoalesced=11 hopLastWait=0.1049s
```

### 長時間・最終点
```
[NekozeFix Metrics] arrivals=15562 inferences=7781 drops=7781 totalInferenceTime=128.8709s inputFPS=24.90 inferFPS=12.45 avgInferTime=0.0166s dropRate=50.00% residual=0.0638s limitFPS=15.0 hopSubmits=7781 hopDelivers=4038 hopCoalesced=3743 hopLastWait=0.0800s
```

## 変更履歴

| 日付 | 変更内容 | 記録者 |
|------|----------|--------|
| 2026-10-14 | mini実機で6シナリオ計測。hop系・FPS系を記録。通知遅延・CPU・復帰定量は未計測として明記 | 手動操作 + エージェント記録 |
