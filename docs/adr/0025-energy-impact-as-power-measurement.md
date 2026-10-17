# 実機電力の計測に Xcode Energy Report（ゲージ評価＋Average Component Utilization）を用いる

電力の実測手段として、対象機（iOS 18.7.7）で利用可能な Xcode の Energy Report を用いる。表示される指標は (a) Average Energy Impact ゲージの色評価（Low / High / Very High）と (b) Average Component Utilization の領域別%（Overhead / CPU / GPU / Network / Location / Display）である。同一端末・同一セッションで通常時と暗転時を同条件で取得し、相対比較する。数値の「Energy Impact スコア」は Xcode 26 では表示されないため用いない。校正電力（W / mAh）ではないため、絶対値や他セッション間の比較には用いない。

## 詳細

- 計測手段: 実機を Xcode から Run し、Debug navigator の Energy Impact ゲージをクリックして Energy Report を開く（`IDEIODebugGaugesCore` の `EnergyGauge`）。
- 記録する指標: Average Energy Impact ゲージの色評価と、Average Component Utilization の領域別%（Overhead / CPU / GPU / Network / Location / Display）。
- 比較則: 同一端末・同一セッション・同条件（同姿勢・同取得時間・同バックグラウンド状態）で通常時と暗転時を取得し、相対比較のみ行う。
- 未計測・推定の扱い: 取得していない消費電力・持続時間、および実測指標からの換算・外挿による推計は記録に含めない（要件7.2・8.2）。
- 記録: `measurements-4-2.md` の「電力」欄に、ゲージ評価と領域別%＋計測手段＋条件を付して記す。

## 検討した選択肢

- Instruments Power Profiler: 校正電力が得られるが iOS 26.0 以上を要求し、対象機（iOS 18.7.7）では取得不可（却下）。
- 数値の Energy Impact スコア: Xcode 26 では表示されず取得できない（却下）。
- 電池残量（%）の長時間差分計測: 実電力に近いが所要時間が長く、他要因の混入と分解能不足が大きい（却下）。
- 実測指標から消費電力への換算: 相関が未検証であり、要件7.2・8.2 の推定禁止に抵触する（却下）。

## 今後の対応

- [ ] `measurements-4-2.md` の未計測条件（長時間不在・復帰直後・長時間監視）で Energy Report を実機取得し記録する
- [ ] 電力の絶対値が必要になった場合は、iOS 26.0 以上の端末で Power Profiler 計測へ切り替える（再検証トリガー）
