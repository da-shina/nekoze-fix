# 条件別の実測記録（task 4.2）

本記録は Requirement 7（7.1, 7.2, 7.3）および Requirement 8（8.1, 8.2）に対応する、
条件別の電力・復帰時間・精度の実測記録である。
形式は design.md Testing Strategy「Performance/Load（実機）」および
「実測記録の正準雛形（4spec共通の集約先）」の雛形に従う。
正準雛形の定義自体は design.md にあるため、本記録では定義を重複させず、記入済み記録のみ残す。

## 測定環境と制約

- 測定は実機で実施した。端末は iPhone 13 mini（iPhone14,4）、iOS 18.7.7、
  bundle identifier `com.nekoze.nekoze-fix`。
- 計測手段は `scripts/measure-dim.sh`。`xcrun devicectl device process launch --console` で
  アプリ標準出力（5秒窓の `[NekozeFix Metrics]` ログ）を `/tmp/nekoze-measure/08-dim-<条件>.log` へ中継した。
  段階の観測値（`limitFPS`／`motionFreq`）と判定分布（`judge=g/s/i/a/p`。各5秒窓の
  good/slouch/insufficient/absent/personOnly 回数）はこのログから取得した。
- 制約（暗転中のログ停止）: `enterDimMode()` は `stopMetricsLogging()` を呼ぶため、
  暗転・長時間不在段階の値は通常のログには出力されない。観測のため、計測専用の一時配線
  （`enterDimMode` 内の `stopMetricsLogging()` 呼び出しを一時無効化）を用いた。
  配線は計測後に復元し、コミットしていない（作業ツリーはクリーン）。
  したがって本記録の暗転・長時間不在・復帰の段階観測値は、この一時配線下で取得した値である。
- 電力の計測手段（ADR-0025）: 実機を Xcode から Run し Energy Report（Debug navigator の Energy Impact ゲージ）で取得する **Average Energy Impact ゲージ評価（Low/High/Very High）** と **Average Component Utilization の領域別%（Overhead/CPU/GPU/Network/Location/Display）** を電力の実測値として用いる。同一端末・同一セッションで通常時と暗転時を同条件で取得し相対比較する。数値の Energy Impact スコアは Xcode 26 では表示されない。校正電力（W / mAh）ではないため、絶対値・他セッション間比較には用いない。
  `xctrace` の Power Profiler は iOS 26.0 以上を要求し本機（iOS 18.7.7）では取得できない。
- 復帰時間・検出精度（TP/FP/FN）の定量計測は本セッションでは未実施のため、未計測とする。
- 単体・結合テストの成功は機能的正確性の証拠であり、電力・実機復帰時間・実機検出精度の
  実測値とはみなさない。テスト証拠は各条件の「比較根拠」欄に機能ピンとして記すが、
  電力・復帰時間への推論には用いない。
- 実測していない省電力率・持続時間の推定値は本記録に含めない（7.2）。
- 測定できない項目は未計測として明記する（7.3）。

## 記入用セッション情報（電力計測時に記入）

Energy Impact の相対比較は同一端末・同一セッション内でのみ成立する（ADR-0025）。
以下を測定時に記入し、各条件の「電力」欄の値と対応させる。

```text
セッションID: セッション1
計測日時: 未記入
端末 / OS: iPhone 13 mini（iPhone14,4） / iOS 18.7.7
計測手段: Xcode Energy Report（Average Energy Impact ゲージ評価＋Average Component Utilization の領域別%）
取得時間（各条件）: 未記入
姿勢・背景条件（全条件で統一）: 未記入
```

## 条件別記録（条件名は固定）

### 条件: 通常

```text
条件: 通常
電力: Average Energy Impact ゲージ=Low（緑）／Average Component Utilization: Overhead 0%・CPU 19〜21%・GPU 0.8%・Network 0%・Display 15%（計測手段: Xcode Energy Report。同一セッション・同条件。取得時間 ___分）
復帰時間: 未計測（実機での復帰時間計測は未実施のため）
精度: 未計測（実機での検出精度計測は未実施のため）
比較根拠: 低減比較の基準条件。本条件自体には低減結果はない（比較は「暗転時と通常時の比較」節）。
  実機観測（通常段階・一時配線なし）: limitFPS=15.0, motionFreq=30Hz を 82窓で継続。
  平均 inputFPS=24.89, inferFPS=12.45, dropRate=49.96%, judge 合計 g2450/s85/i9/a0/p126
  （/tmp/nekoze-measure/08-dim-normal.log）。
  機能ピン（実測値ではなく機能的正確性の証拠）:
  通常段階の上限・頻度設定と3秒連続確定判定の意味不変は結合検証で green
  （PostureSessionManagerTests 全 green、FrameThrottleTests 23/23）。
```

### 条件: 暗転

```text
条件: 暗転
電力: Average Energy Impact ゲージ=Low（緑）／Average Component Utilization: Overhead 0%・CPU 16〜19%・GPU 4.2〜4.4%・Network 0%・Display 2.6〜2.8%（計測手段: Xcode Energy Report。通常と同一セッション・同条件）
復帰時間: 未計測（実機での復帰時間計測は未実施のため）
精度: 未計測（実機での検出精度計測は未実施のため）
比較根拠: 通常時との実測比較は「暗転時と通常時の比較（8.1, 8.2）」節に記載。
  電力: 通常 Display 15%／CPU 19〜21% → 暗転 Display 2.6〜2.8%／CPU 16〜19%（同一セッション・同条件）。
  実機観測（暗転段階・一時配線使用）: 通常 limitFPS=15.0/motionFreq=30Hz から
  暗転 limitFPS=10.0/motionFreq=15Hz への切替えを観測。
  judge 合計 g221/s31/i4/a809/p14（26窓）。遷移直後に limitFPS=10.0/motionFreq=30Hz の
  過渡窓を1つ観測（上限と取得頻度の更新順序による過渡）。
  機能ピン（実測値ではなく機能的正確性の証拠）:
  暗転段階への遷移・上限／頻度の低下指示・解除時の通常戻しは検証で green
  （DimPowerPolicyTests 10/10、FrameThrottleTests 23/23、
  PostureSessionManagerTests 全 green。暗転中の低下・復帰・3秒確定ピンを含む）。
  暗転中のカメラ取得は継続する（task 4.1 評価記録。停止経路なし）。
```

### 条件: 長時間不在

```text
条件: 長時間不在
電力: 未計測（部分記録: Average Component Utilization の CPU成分のみ 37〜39%。Display/GPU/Overhead/Network とゲージ評価は未計測。セッション1・Xcode Energy Report）
復帰時間: 未計測（実機での復帰時間計測は未実施のため）
精度: 未計測（実機での検出精度計測は未実施のため）
比較根拠: 長時間不在段階の全成分比較は未実施のため、低減確認なし（Energy Report は CPU成分のみ実測）。
  CPU成分は 37〜39% で通常（19〜21%）より高く、暗転モード内での更なる低減は実測で確認できない。
  実機観測（長時間不在段階・一時配線使用）: 暗転中の連続不在（judge の a が継続）により
  motionFreq が 15Hz→10Hz へ低下（limitFPS=10.0 のまま）することを観測。
  judge 合計 g0/s7/i3/a68/p5（2窓）。人物再検出で暗転段階（motionFreq=15Hz）へ戻ることも観測。
  機能ピン（実測値ではなく機能的正確性の証拠）:
  暗転中の連続不在による長時間不在段階への遷移・更なる低下指示・
  人物再検出時の暗転段階への戻りは検証で green
  （DimPowerPolicyTests 10/10、不在しきい値境界を含む）。
```

### 条件: 復帰直後

```text
条件: 復帰直後
電力: 未計測（部分記録: Average Component Utilization の CPU成分のみ 19〜21%。他成分とゲージ評価は未計測。セッション1・Xcode Energy Report）
復帰時間: 未計測（実機での復帰時間の定量計測は未実施のため）
精度: 未計測（実機での検出精度計測は未実施のため）
比較根拠: 復帰直後の全成分比較は未実施のため、低減確認なし（CPU成分のみ実測 19〜21%）。
  実機観測（復帰直後・一時配線使用）: 暗転解除により limitFPS=10.0→15.0,
  motionFreq=15Hz→30Hz へ戻ることを観測。過渡窓で limitFPS=15.0/motionFreq=15Hz を1つ観測
  （上限の先行復帰。ADR-0024 の更新順序どおり）。復帰所要時間の定量値は未計測。
  機能ピン（実測値ではなく機能的正確性の証拠）:
  暗転解除・監視開始・フォアグラウンド復帰の全経路での通常戻し、
  および復帰直後の判定・通知仕様の不変は結合検証で green
  （PostureSessionManagerTests 全 green）。
```

### 条件: 長時間監視

```text
条件: 長時間監視
電力: 未計測（記入欄: Average Energy Impact ゲージ評価 ___／Average Component Utilization の領域別% ___／計測手段: Xcode Energy Report／条件: セッション ___・取得時間 ___分・姿勢 ___）
復帰時間: 未計測（実機での復帰時間計測は未実施のため）
精度: 未計測（実機での検出精度計測は未実施のため）
比較根拠: 通常時との実測比較は未実施のため、低減確認なし（実機計測待ち）。
  本条件（長時間の連続監視）は本セッションでは未実施のため、実機観測なし。
  機能ピン（実測値ではなく機能的正確性の証拠）:
  長時間動作に関わる段階管理・起停・背景移行・抑止継続の既存回帰は green
  （tasks 2.3〜3.3 の検証記録を参照）。
```

## 暗転時と通常時の比較（8.1, 8.2）

- 同一端末・同一セッション・同条件での実測比較（ADR-0025。Average Energy Impact ゲージ評価＋Average Component Utilization の領域別%）:
  - 通常: ゲージ=Low（緑）／Overhead 0%・CPU 19〜21%・GPU 0.8%・Network 0%・Display 15%
  - 暗転: ゲージ=Low（緑）／Overhead 0%・CPU 16〜19%・GPU 4.2〜4.4%・Network 0%・Display 2.6〜2.8%
  - 差分: Display 15%→2.7%（約 -12.3pp。輝度0による主要な低下）、CPU 約 -2pp、GPU は +3.5pp へ上昇。
    Average Energy Impact ゲージ評価は両者 Low で差が出ない。
- 判定: 主要な消費領域である Display 利用が暗転で大きく低下し、CPU も微減した。同一端末・同一セッションの
  実測値に基づき、暗転時の低減を確認する（8.1/8.2）。ただしゲージ評価は両者 Low で差が無く、GPU は上昇して
  いるため、低減の定量は成分利用率の範囲に限る。実測指標からの消費電力換算・外挿は行わない（8.2）。
- 未計測・部分記録の扱い: 長時間不在・復帰直後は Average Component Utilization の CPU成分のみ実測
  （セッション1。長時間不在 37〜39%／復帰直後 19〜21%）。他成分・ゲージ評価、長時間監視の電力、
  および全条件の復帰時間・検出精度は未計測。CPU成分のみでは同一セッションの全成分比較にならないため、
  これらは本節の低減確認の対象外とする。
- 長時間不在の実測: CPU成分が通常（19〜21%）より高い（37〜39%）。暗転モード内での更なる低減は実測では
  確認できない（顔フォールバック（ADR-0021）による Vision 負荷の観測 `absent-vision-cost-4-2.md` と整合）。
- 機構の実機観測（低減の確認ではない）: 暗転段階では推論上限（15→10）と
  センサー取得頻度（通常30Hz→暗転15Hz→長時間不在10Hz）が通常より低い設定値へ
  切り替わることを実機で観測した。制御量の切替えの観測であり、上記の低減確認とは別の根拠である。

## 参照

- requirements.md Requirement 7（7.1, 7.2, 7.3）、Requirement 8（8.1, 8.2）
- design.md Testing Strategy「Performance/Load（実機）」、
  「実測記録の正準雛形（4spec共通の集約先）」（条件名・必須項目・雛形の定義元）
- `docs/adr/0025-energy-impact-as-power-measurement.md`（電力の実測手段：Energy Report のゲージ評価＋Average Component Utilization の採用と制約）
- task 4.1 評価記録 `camera-stop-evaluation-4-1.md`（暗転中のカメラ取得継続・停止経路なしの根拠）
- 実測ログ: `/tmp/nekoze-measure/08-dim-normal.log`（通常）、`/tmp/nekoze-measure/08-dim-dim.log`（暗転・長時間不在・復帰）
- task 4.2 付随記録 `absent-vision-cost-4-2.md`（長時間不在時の Vision 負荷調査。別spec提案を含む）
