# 条件付き顔検出（二段階perform）

## 概要

長時間監視中の不要な顔推論を削減するため、`PoseDetector.detect` の無条件2リクエスト同時実行を姿勢優先の二段階実行に変える。人物検出の意味（姿勢あり・人物あり姿勢不明・人物不在の3値）と呼び出し側・スレッド構造は変えない。

## 用語定義

- **姿勢有効**：人体姿勢観測が1件以上あること（`poseResult != nil`）。キーポイントの信頼度・点数は含まない
- **顔省略**：姿勢有効により顔推論を実行しないこと
- **顔実行**：姿勢観測ゼロ件により顔推論を実行すること
- **成功経路**：観測あり→顔省略の経路。`faceSkippedCount` で数える
- **失敗経路**：観測ゼロ→顔実行の経路。`faceExecutedCount` で数える
- **顔フォールバック**：キーポイント不足時に顔で人物有無を判定する振る舞い

## 詳細

- 姿勢フェーズで観測ゼロ件（`poseResult == nil`）の場合のみ顔フェーズを実行する。信頼度フィルタや点数判定は分岐に持ち込まない（Q1確定）。現行合成式 `poseResult ?? (faceBounds != nil ? .personOnly : .absent)` と同一の出力を保証する唯一の条件である
- 観測あり・4点全 `nil` の `PoseFrame` も成功経路とみなし顔省略する（Q2確定）。`.pose(全nil)` は `processDetection` で `.pose` 経路（`isShoulderMissing=false`・ホールド継続）に入り、`.personOnly` 経路（肩欠測デバウンス）とは別扱いのままである。この差異維持は意図的であり、Session層に手を入れない（Q7確定）
- `perform` 分割後の例外扱いは現行則維持：姿勢単独・顔単独 `perform` の例外時は即 `.absent`（顔へ進まない）。コールバック内個別エラーのみ `poseResult=nil` のまま顔フェーズへ進む。無効バッファも `.absent` 維持（Q5確定）
- 呼び出し側は無変更：`captureOutput`（detectionQueue同期→MainActor hop）、`processDetection` の3経路・向き別閾値・片側継続・近側選択（鋭角大＋5度未満維持）・猶予・校正／監視遷移のすべてを維持する
- 計測は `PoseDetector` 私有の錠付き小構造体に隔離する（Q3確定）。`faceSkippedCount・faceExecutedCount・poseTotalTime・faceTotalTime` の4フィールド＋`NSLock`＋`snapshot()`複写＋`reset()`、常時累積・永続化なし・外部送出なし・結果不変（Q6確定）
- 実機計測は `ios17-baseline` 手順準拠の実機で行い、両経路の回数・時間＋入力FPS独立確認のみ記録する。削減率・持続時間の未実測記載は禁止、`research.md` 末尾実測節に追記し本ADRから参照、下流 `vision-fps-throttle` へ引き渡す（Q9確定）
- 検証は `PoseDetectorTests` のみ編集（2.1）、他範囲は編集なし再実行のみ（2.2）。並列根拠は「2.2は実行のみ」（Q10確定）

## Considered Options

- 単一perform＋結果破棄：変更最小だが推論コストが減らない（却下）
- 検出層での有効点数判定（キーポイント数・信頼度で分岐）：削減調整は可能だがSession層閾値則と二重定義になり意味が変わる（却下）
- Session層での集計：表示と結合するが層をまたぎ、推論点での取りこぼしが出る（却下、PoseDetector内隔離を採用）
- 姿勢単独perform例外時に顔へ進む案：フォールバック機会は最大化できるが、現行の即absent則と到達性が変わる（却下）

## Follow-up

- [ ] 実機で成功経路・失敗経路の回数・時間を実測し `research.md` に記録する（tasks 3.1）
- [ ] 下流 `vision-fps-throttle`・`mainactor-throttle` へ計測形式を引き渡す
- [ ] 分岐への信頼度混入・公開署名変更・3値意味変更は本ADRの再検証を要する
