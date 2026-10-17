# 長時間不在時の Vision 負荷調査（task 4.2 付随記録）

## 結論

暗転の長時間不在段階では、推論FPS上限を10へ下げても、人物不在により Body Pose 観測が0件となり
顔検出フォールバック（ADR-0021、`PoseDetector.detect` 119〜141行）が**毎推論で実行**される。
このため推論あたりの Vision 時間が約2倍（約17ms→約34ms）になり、
**窓あたりの Vision 総量は通常(15fps)より増える**。
Requirement 2.2「暗転直後よりさらに低下させる」は、推論FPS上限では満たすが、
実 Vision 負荷では満たしていない（むしろ増える）。

## 計測方法

- 実機 iPhone 13 mini（iPhone14,4） / iOS 18.7.7。
- `scripts/measure-dim.sh` で5秒窓ログ `[NekozeFix Metrics]` を取得。
- `PoseDetector.Metrics`（`faceExecutedCount` / `faceSkippedCount` / `poseTotalTime` / `faceTotalTime`）を
  計測専用の一時配線で窓ログへ出力し、計測後に撤去（未コミット）。暗転中のログ停止も一時無効化した。
- 取得ログ: `/tmp/nekoze-measure/08-dim-vision.log`。

## 実測値（窓あたり平均。limitFPS/motionFreq で区分）

| 状態 (limitFPS/motionFreq) | 窓数 | 推論/窓 | visionExec/窓 | visionSkip/窓 | poseTime/窓 | faceTime/窓 | 推論あたりVision |
|---|---|---|---|---|---|---|---|
| 通常 15.0/30Hz | 2 | 90.5 | 0.5 | 60.0 | 1.040s | 0.042s | 約17ms |
| 暗転 10.0/30Hz（在席） | 1 | 166 | 0.0 | 45.0 | 0.743s | 0s | 約17ms |
| 不在 10.0/15Hz | 13 | 41.0 | 39.3 | 2.2 | 0.732s | 0.664s | 約35ms |
| 長時間不在 10.0/10Hz | 6 | 41.5 | 41.5 | 0.0 | 0.721s | 0.673s | 約34ms |

- 在席: Body Pose 成功 → 顔パス省略（`visionSkip` 大・`faceTime`≈0）。
- 不在: Body Pose 0件 → 顔パス実行（`visionExec`≈推論数・`faceTime`≈16ms）。
- Vision 総量/窓: 通常約1.08s（15fps）に対し不在約1.39s（10fps）で約29%増。

## 解釈と限界

- 原因は上流 vision-face-conditional（ADR-0021）の仕様であり、dim-mode-saving は導入していない。
- Xcode Debug navigator の CPU が不在時に約2倍という観測（セッション1）は、Vision 分（約+6点相当）だけでは
  説明しきれず、Debug/計測条件・固定コストの寄与が残る。正確な内訳は Activity Monitor / Time Profiler が必要で、
  本記録時点では未計測。
- 本調査の計測値は窓ログ由来の Vision 時間であり、校正された電力（W / mAh）ではない。

## 別spec 提案（本specスコープ外）

長時間不在時の視覚処理削減を独立specとして提案する。候補:

- 不在確定後に顔フォールバックを間引く／停止する
- 不在段階の推論上限・検出方式を再設定する（例: 顔フォールバックを低頻度化）

いずれも ADR-0021 の検出意味（「顔のみでも人物あり」）を変えるため、設計判断（ADR）を要する。
ロードマップに候補として追記した（`.kiro/steering/roadmap.md`）。

## 参照

- `docs/adr/0021-vision-face-conditional.md`（顔検出の条件付き実行）
- `docs/adr/0024-dim-absent-effective-rate.md`（長時間不在の実効実行数による低下。本調査はその前提に再検証を要求）
- `NekozeFix/Services/PoseDetector.swift`（`detect` 119〜141行、`Metrics`）
- `measurements-4-2.md`（task 4.2 の条件別実測記録）
