# 実機計測記録: vision-fps-throttle (タスク 3.3)

## 計測環境

| 項目 | 値 |
|------|-----|
| デバイス | iPad (9th generation) / iPhone 13 mini |
| iOS バージョン | iPad: 18.7.8 (22H352、計測時取得） |
| アプリバージョン | NekozeFix (vision-fps-throttle ブランチ @84f36b6、Debug-iphoneos) |
| カメラ位置 | 前面カメラ (フロント) |
| セッションプリセット | VGA 640×480 (4:3) |
| 計測日時 | 2026-10-11 |
| 計測者 | 自律計測（エージェント） |

## 計測手順

### 事前準備
1. デバイスをデスクに固定し、前面カメラが上半身を捉える位置に置く
2. アプリを起動し、キャリブレーションを完了させる（基準姿勢を登録）
3. 監視モードに入り、ログ出力が始まることを確認（Xcode コンソールまたは `xcrun devicectl device log`）
4. 各シナリオで **最低 30 秒以上** 継続し、安定した値を取得する

### ログ取得方法
```bash
# デバイスログをリアルタイムで取得（macOS 側で実行）
xcrun devicectl device log --device 1B98037F-C505-52F4-A04A-57027D130BD7 --process NekozeFix --predicate 'eventMessage contains "[NekozeFix Metrics]"'
```

または Xcode の Devices and Simulators ウィンドウからコンソールを開く。

> 注意: 本環境（Xcode 付属の devicectl）には `device log` サブコマンドがなく、
> 上記コマンドはそのままでは動かない。自律計測では `device process launch
> --terminate-existing --console <bundleID>` の標準出力中継で取得した。

### ログ形式
```
[NekozeFix Metrics] arrivals=150 inferences=75 drops=75 totalInferenceTime=1.2345s inputFPS=30.00 inferFPS=15.00 avgInferTime=0.0165s dropRate=50.00% residual=0.0500s limitFPS=15.0
```

各フィールド:
- `arrivals`: カメラから到達したフレーム数（入力累積）
- `inferences`: Vision 推論を実行した回数（推論累積）
- `drops`: 間引きにより破棄されたフレーム数
- `totalInferenceTime`: 推論所要時間の累積（秒）
- `inputFPS`: 入力 FPS = arrivals / 経過秒
- `inferFPS`: 推論 FPS = inferences / 経過秒
- `avgInferTime`: 平均推論時間 = totalInferenceTime / inferences
- `dropRate`: ドロップ率 = drops / arrivals
- `residual`: 推論間の残余時間 = (1/inferFPS) - avgInferTime（キュー待ち時間ではない。待機列を持たない破棄設計のため真の待ち時間は計測不可。レビュー指摘 4241621575 対応で `estWait` から改名）
- `limitFPS`: 現在の推論 FPS 上限設定値

---

## シナリオ別計測記録

### 設定 A: 現状（無制限 / 実質 1000 FPS 相当）
> `FrameThrottle.defaultMaxFPS` を一時的に大きな値（例: 1000）に変更してビルド、または `setLimit(1000)` を呼ぶ

| シナリオ | 経過秒 | arrivals | inferences | drops | totalInferenceTime | inputFPS | inferFPS | avgInferTime | dropRate | residual | 備考 |
|----------|--------|----------|------------|-------|-------------------|----------|----------|--------------|----------|---------|------|
| 通常（正座・良好姿勢） | | | | | | | | | | | |
| 暗転モード | | | | | | | | | | | |
| 人物不在（カメラを塞ぐ/離れる） | | | | | | | | | | | |
| 復帰（不在→着席） | | | | | | | | | | | |
| 猫背（意図的に猫背姿勢） | | | | | | | | | | | |
| 長時間（10分連続監視） | | | | | | | | | | | |

### 設定 B: 15 FPS 制限（現行暫定デフォルト）
> `FrameThrottle.defaultMaxFPS = 15.0` のままビルド

| シナリオ | 経過秒 | arrivals | inferences | drops | totalInferenceTime | inputFPS | inferFPS | avgInferTime | dropRate | residual | 備考 |
|----------|--------|----------|------------|-------|-------------------|----------|----------|--------------|----------|---------|------|
| 通常（正座・良好姿勢） | | | | | | | | | | | |
| 暗転モード | | | | | | | | | | | |
| 人物不在（カメラを塞ぐ/離れる） | | | | | | | | | | | |
| 復帰（不在→着席） | | | | | | | | | | | |
| 猫背（意図的に猫背姿勢） | | | | | | | | | | | |
| 長時間（10分連続監視） | | | | | | | | | | | |

### 設定 C: 10 FPS 制限
> `setLimit(10.0)` を呼ぶ、または `FrameThrottle.defaultMaxFPS = 10.0` に変更してビルド

| シナリオ | 経過秒 | arrivals | inferences | drops | totalInferenceTime | inputFPS | inferFPS | avgInferTime | dropRate | residual | 備考 |
|----------|--------|----------|------------|-------|-------------------|----------|----------|--------------|----------|---------|------|
| 通常（正座・良好姿勢） | | | | | | | | | | | |
| 暗転モード | | | | | | | | | | | |
| 人物不在（カメラを塞ぐ/離れる） | | | | | | | | | | | |
| 復帰（不在→着席） | | | | | | | | | | | |
| 猫背（意図的に猫背姿勢） | | | | | | | | | | | |
| 長時間（10分連続監視） | | | | | | | | | | | |

---

## CPU 使用率計測（Instruments または devicectl）

| 設定 | シナリオ | CPU 平均 (%) | CPU ピーク (%) | 計測時間 | 計測方法 |
|------|----------|-------------|---------------|----------|----------|
| 現状（無制限） | 通常 | | | | |
| 現状（無制限） | 長時間 | | | | |
| 15 FPS | 通常 | | | | |
| 15 FPS | 長時間 | | | | |
| 10 FPS | 通常 | | | | |
| 10 FPS | 長時間 | | | | |
| 15 FPS | stagingなし（自律・参考） | — | — | 約45秒 | 未計測（本環境の devicectl にCPU取得手段なし） |

**計測方法の例:**
```bash
# プロセスリストから CPU 使用率を取得（1秒間隔でサンプリング）
xcrun devicectl device process list --device 1B98037F-C505-52F4-A04A-57027D130BD7 --include-cpu

# または Instruments の Time Profiler / Activity Monitor で記録
```

---

## 自律計測記録（参考・stagingなし・2026-10-11）

> 対話式stagingなしで取得した参考値。シナリオ別表・制限値選定には用いない。

### 取得条件

| 項目 | 値 |
|------|-----|
| デバイス | iPad (9th generation)、iOS 18.7.8 |
| ビルド | vision-fps-throttle @84f36b6（Debug-iphoneos） |
| 設定 | 15 FPS既定（`limitFPS=15.0` をログで確認） |
| 操作 | 導入後の起動のみ。タップ・stagingなし |
| 取得方法 | `process launch --console` の標準出力中継 |
| 取得区間 | 起動後約5秒〜約45秒の9点（5秒間隔）。約50秒以降は出力停止（原因未確認）。75秒時点で終了 |

### 指標サマリ（最終連続点・約35秒経過）

| arrivals | inferences | drops | totalInferenceTime | inputFPS | inferFPS | avgInferTime | dropRate | residual |
|----------|------------|-------|-------------------|----------|----------|--------------|----------|----------|
| 834 | 418 | 416 | 18.6147s | 23.83 | 11.94 | 0.0445s | 49.88% | 0.0392s |

- `inferFPS=11.94` は上限15を下回る（入力23.83fps・間隔1/15秒の間引きとして整合）。
- 約35〜40秒付近で計数区間が再開始している（arrivals 834→120。原因未確認）。

### 制約・未確認事項

- 被写体の有無・姿勢、アプリのフェーズ（校正中／監視中）は未確認（UI非観測）。
- CPU使用率は未計測（本環境の devicectl にCPU取得手段なし）。
- 現状（無制限）・10 FPS・長時間・シナリオ別の値は未計測。制限値の選定は行わない。

---

## 比較・選定分析

### 入力 FPS・推論 FPS の比較サマリ

| 設定 | 通常時 inputFPS | 通常時 inferFPS | 猫背時 inferFPS | 暗転時 inferFPS | 不在時 inferFPS | 長時間 inferFPS (10分後) |
|------|----------------|-----------------|-----------------|-----------------|-----------------|------------------------|
| 現状（無制限） | | | | | | |
| 15 FPS | | | | | | |
| 10 FPS | | | | | | |

### 推論時間・残余時間の比較

| 設定 | 平均推論時間 (ms) | 推論間の残余時間 (ms) | ドロップ率 |
|------|------------------|------------------|-----------|
| 現状（無制限） | | | |
| 15 FPS | | | |
| 10 FPS | | | |

### CPU 使用率の比較

| 設定 | 通常時 CPU 平均 | 長時間 CPU 平均 | ピーク CPU |
|------|----------------|----------------|-----------|
| 現状（無制限） | | | |
| 15 FPS | | | |
| 10 FPS | | | |

---

## NFR 8.1 整合性確認

> **NFR 8.1**: 推論 FPS は 15 fps 以上の構造的上限を持たせず、入力 FPS と推論 FPS を独立に制御・計測できること

| 検証項目 | 結果 | 根拠（実測値） |
|----------|------|----------------|
| 推論 FPS が 15 fps を超える構造になっていないか | | |
| 入力 FPS と推論 FPS が独立に計測できているか | | |
| 3秒確定判定の意味が間引き前後で変わらないか | | (タスク 3.2 で検証済み) |

---

## 制限値の選定根拠

### 選定された値: **___ FPS**

### 選定理由

1. **3秒確定判定への影響**: 間引き下でも 3 秒連続猫背検知で確定判定が出ること（タスク 3.2 で確認済み）
2. **推論 FPS の実測値**: 
3. **CPU 使用率の削減効果**: 
4. **残余時間・ドロップ率の許容度**: 
5. **バッテリー持続時間への推定貢献**: (未計測・推定記載禁止)

---

## 未計測項目（要件 7.3 対応）

以下の項目は **実測していない** ため、効果として記載しない：

| 項目 | 未計測理由 | 今後の計測予定 |
|------|------------|----------------|
| CPU使用率の自律計測分 | 本環境の devicectl にCPU取得手段なし（`device process list --include-cpu` も不在） | Instruments または別 toolchain で検証 |
| 真のキュー待ち時間 | 待機列を持たない破棄設計のため計測不可（`residual` は推論間の残余時間を記録） | N/A |
| 実際のバッテリー持続時間の延長 | 長時間（数時間）の実測には時間と環境制御が必要 | 別途実機での長時間運用テストで検証 |
| 発熱抑制効果 | サーマルセンサー読み取りが必要 |  |
| メモリ使用量の変化 | 間引きによるメモリ圧迫変化は軽微と判断 |  |
| ネットワーク通信への影響 | 本アプリはネットワーク通信を行わない | N/A |
| 通知音再生の精度への影響 | 間引きは判定ロジック前段であり影響なし（設計上保証） | タスク 3.2 で非回帰確認済み |

---

## 計測ログ生データ（参考）

### 設定 A: 現状（無制限）
```
[ここにコンソールログを貼り付け]
```

### 設定 B: 15 FPS
```
[NekozeFix Metrics] arrivals=114 inferences=58 drops=56 totalInferenceTime=3.0407s inputFPS=22.79 inferFPS=11.60 avgInferTime=0.0524s dropRate=49.12% residual=0.0338s limitFPS=15.0
[NekozeFix Metrics] arrivals=234 inferences=118 drops=116 totalInferenceTime=5.7974s inputFPS=23.40 inferFPS=11.80 avgInferTime=0.0491s dropRate=49.57% residual=0.0356s limitFPS=15.0
[NekozeFix Metrics] arrivals=354 inferences=178 drops=176 totalInferenceTime=8.7268s inputFPS=23.60 inferFPS=11.87 avgInferTime=0.0490s dropRate=49.72% residual=0.0352s limitFPS=15.0
[NekozeFix Metrics] arrivals=474 inferences=238 drops=236 totalInferenceTime=11.5641s inputFPS=23.70 inferFPS=11.90 avgInferTime=0.0486s dropRate=49.79% residual=0.0354s limitFPS=15.0
[NekozeFix Metrics] arrivals=594 inferences=298 drops=296 totalInferenceTime=13.8788s inputFPS=23.76 inferFPS=11.92 avgInferTime=0.0466s dropRate=49.83% residual=0.0373s limitFPS=15.0
[NekozeFix Metrics] arrivals=714 inferences=358 drops=356 totalInferenceTime=15.9220s inputFPS=23.80 inferFPS=11.93 avgInferTime=0.0445s dropRate=49.86% residual=0.0393s limitFPS=15.0
[NekozeFix Metrics] arrivals=834 inferences=418 drops=416 totalInferenceTime=18.6147s inputFPS=23.83 inferFPS=11.94 avgInferTime=0.0445s dropRate=49.88% residual=0.0392s limitFPS=15.0
[NekozeFix Metrics] arrivals=120 inferences=60 drops=60 totalInferenceTime=3.0939s inputFPS=23.99 inferFPS=12.00 avgInferTime=0.0516s dropRate=50.00% residual=0.0318s limitFPS=15.0
[NekozeFix Metrics] arrivals=241 inferences=120 drops=121 totalInferenceTime=5.2095s inputFPS=24.09 inferFPS=12.00 avgInferTime=0.0434s dropRate=50.21% residual=0.0399s limitFPS=15.0
```

### 設定 C: 10 FPS
```
[ここにコンソールログを貼り付け]
```

---

## 変更履歴

| 日付 | 変更内容 | 記録者 |
|------|----------|--------|
| 2026-10-11 | テンプレート作成 | |
| 2026-10-11 | 自律計測（stagingなし・15FPS既定・9点）を記録。選定は未実施 | 自律計測（エージェント） |