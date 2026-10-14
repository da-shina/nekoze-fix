# 実機計測記録: motion-frequency (タスク 5.1 前段・机上静止)

## 計測環境

| 項目 | 値 |
|------|-----|
| デバイス | iPhone 13 mini (iPhone14,4、mini。先行記録と同一端末) |
| iOS バージョン | 18.7.7 (22H340、devicectl取得) |
| アプリバージョン | NekozeFix (feature/motion-frequency @ab96b60 ＋ 未コミット配線「motion計数のMetrics行同梱・shortLabel」。TEMP自動開始・頻度既定値変更は撤去済み) |
| カメラ位置 | 前面カメラ (フロント) |
| セッションプリセット | VGA 640×480 (4:3) |
| 計測日時 | 2026-10-14 23:43〜2026-10-15 00:01 (各周波数330秒リレー×3本、中継連続) |
| 計測者 | エージェント単独 (机上静止のため人的操作なし。人物被写体の有無は不統制) |
| 取得方法 | `devicectl device process launch --device mini --terminate-existing --console com.nekoze.nekoze-fix -- --measureAutoStart` の標準出力中継。Xcodeコンソールと同一の `print("[NekozeFix Metrics]...")` 系列 |

## 配線の実装 (本計測の前提)

ADR-0023指定の「`motionSamples/motionVisible/motionReads/motionInvalidReads` を既存 `[NekozeFix Metrics]` 同一行に同梱」が未実装だったため、以下を追加した上で計測した (振る舞い変更なし。計数・判定則は不変):

- `startMetricsLogging()` で `motionService.startMeasuring(note:)` を開始する
- `logMetricsSnapshot()` で当該5秒窓の `stopMeasuring()` 結果を同一行へ同梱し、次窓の計測を直ちに再開する
- ログ条件付記用の `MotionUpdateFrequency.shortLabel` ("30Hz"/"15Hz"/"10Hz") を追加する

計測用の起動引数 (`measureAutoStart` 検出によるSplash自動開始) と頻度既定値の一時変更は計測後に撤去し、残留がないことを `git diff` と grep で確認した。

## ログ形式

```
[NekozeFix Metrics] arrivals=... inferences=... drops=... totalInferenceTime=...s inputFPS=... inferFPS=... avgInferTime=...s dropRate=...% residual=...s limitFPS=15.0 hopSubmits=... hopDelivers=... hopCoalesced=... hopLastWait=...s motionFreq=30Hz motionSecs=5.0s motionSamples=... motionVisible=... motionReads=... motionInvalid=... motionNote=freq=30Hz
```

- `motionSamples`: 当該5秒窓の端末計測機能からの重力サンプル到着回数 (background一段目の前で数える)
- `motionVisible`: 同窓の公開値 (`latestGravityInKeypointSpace`) 書換え回数 (実質変化・状態変化のみ)
- `motionReads`: 同窓の判定読取りに付随した参照記録回数 (`.pose` 系フレームの `analyze` 実行と1:1。不在系・顔のみ系は重力を読まないため含まない)
- `motionInvalid`: 同窓の読取り時に公開値が nil だった回数
- `motionSecs`: 計測窓の実測期間 (全窓5.0秒)

## シナリオ別計測記録 (mini・机上静止)

> 定常値。各周波数65窓のうち先頭3窓 (起動過渡) を除く62窓の平均。Sequencesは `/tmp/nekoze-measure/` に保存 (`07-motion-30hz/15hz/10hz-stationary.log`)。

| 周波数設定 | 窓数 | samples/窓 (→/秒) | visible/窓 | 抑制通過率 (visible/samples) | reads/窓 | invalid | inputFPS | inferFPS | dropRate |
|-----------|------|-------------------|-----------|------------------------------|----------|---------|----------|----------|----------|
| 30Hz | 62 | 166.48 (33.30/s) | 6.29 | 3.8% | 29.53 | 0 | 24.84 | 12.43 | 49.97% |
| 15Hz | 62 | 71.34 (14.27/s) | 6.27 | 8.8% | 28.31 | 0 | 24.86 | 12.44 | 49.97% |
| 10Hz | 62 | 49.95 (9.99/s) | 5.23 | 10.5% | 27.92 | 0 | 24.86 | 12.44 | 49.97% |

## 所見 (実測のみ)

- 取得間隔の実測精度: 10Hz設定は要求通り (9.99/s)。15Hz設定はやや不足 (14.27/s、要求の約95%)。30Hz設定は要求を超過 (33.30/s、要求の約111%)。端末側の配信粒度であり、本機能の制御外。判定パイプライン指標への影響は下記の通りなし。
- 二段抑制の end-to-end (samples→visible): 静止時でも公開値は約1回/秒で更新される。暫定許容差 `1e-4` では机上静止の重力ジッタを完全抑制できない。許容差の確定 (`00-gravity-noise`: 机置き・手持ち静止各5分＋動作、`|Δu|` p50/p95/max、`ノイズp99 < ε < 動作p5`) は未実施のため残作業とする。
- 参照記録の意味: `motionReads` は Vision推論回数 (`inferences`、約62/窓) とは一致しない。不在系・顔のみ系は `processDetection` の早期復帰により重力を読まず、`analyze` 実行 (`.pose` 系のみ、約28〜30/窓) と1:1に対応する。Task 3の「読取りのつど通知」はコード隣接と単一経路により満たす。今回の窓で `motionInvalid=0` (公開値は全読取りで非nil。平置き等の無効経路なし)。
- 映像・推論への影響: `inputFPS` / `inferFPS` / `dropRate` は3周波数で小数2桁まで一致 (24.84〜24.86 / 12.43〜12.44 / 49.97%)。取得頻度の変更は Vision パイプラインの処理量・間引き率を変えない。人物あり時の判定一致 (判定一致100%) は別人手シナリオのため未計測。

## 未計測項目 (Req 7.2/7.3対応)

以下の項目は **実測していない** ため、効果として記載しない:

| 項目 | 未計測理由 | 今後の計測予定 |
|------|------------|----------------|
| 電力 (省電力率・持続時間延長) | 本環境の `xctrace list templates` に Energy Log がなく、iOS実機の電力をCLI取得する手段がない | Instruments (Energy Log) での別途取得。取得までは選定しない (ADR-0023の見送り則) |
| 許容差の確定 (`00-gravity-noise`) | 分布計測 (机置き・手持ち静止各5分＋動作) 未実施 | tasks 5.1前段として実施し、`equalityTolerance` を確定する |
| 人物あり判定一致 (同一姿勢・回転追従・復帰時間・3秒確定則) | 被写体となる人的操作が必要で、エージェント単独では実施不可 | 手動シナリオ操作 (通常・猫背・復帰の各5分×3周波数) ＋ エージェントのログ中継・保存 |
| 通知遅延の周波数別比較 | 人物あり確定事象が必要 | 上記と同時取得 (画面収録の差分算出) |
| CPU平均・ピークの周波数別比較 | 目視・定量とも未取得 | Instruments または Debug Navigator 目視での取得 |

## 暫定判断: 見送り (現状30Hz維持・変更なし)

- 選定基準 (ADR-0023: 各頻度5分×3シナリオ＋判定一致100%、電力定量差なし／精度差1件でも見送り) に対し、電力実測と人物ありシナリオが未達のため、**現時点では選定しない**。既定 `thirtyHz`・暫定許容差 `1e-4` を維持し、頻度関連の追加変更は行わない。
- 本判断は暫定であり、新規ADRは増やさない。電力・人物あり計測の完了時に確定判断を行い、その結果を ADR-0023 へ追記する (ADR-0023「今後の対応」欄の定め通り)。

## 変更履歴

| 日付 | 変更内容 | 記録者 |
|------|----------|--------|
| 2026-10-15 | mini実機で3周波数×机上静止5分を計測。motion系4項目を記録。電力・人物あり・許容差確定は未計測として明記。暫定見送り | エージェント単独 (CLI実行＋ログ取得) |
