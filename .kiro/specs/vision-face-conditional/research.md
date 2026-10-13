# 調査・設計判断記録

---

**目的**: 条件付き顔検出の設計に向けた既存実装の調査結果と判断根拠を記録する。

---

## Summary

- **Feature**: `vision-face-conditional`
- **Discovery Scope**: Extension（既存PoseDetectorの内部ロジック変更）
- **Key Findings**:
  - PoseDetector.detectは顔と姿勢の2リクエストを同一performで無条件実行し、結果合成はposeResult優先・顔フォールバックの順序である
  - 人物検出の意味は検出層で完結する（姿勢観測あり→pose、顔のみ→personOnly、両方なし→absent）
  - 検出層は信頼度フィルタを持たず全点を保持し、向き別閾値はSession層が適用するため、有効性の定義を検出層で変えてはならない

## Research Log

### 拡張点の分析

- **Context**: 顔検出の条件付き実行が現在の人物検出ロジックと同じ意味を保つことを確認するため、PoseDetector.detectと呼び出し側の全経路を調査した
- **Sources Consulted**: NekozeFix/Services/PoseDetector.swift、NekozeFix/Session/PostureSessionManager.swift（captureOutput・processDetection）、NekozeFixTests/PoseDetectorTests.swift
- **Findings**:
  - detectの顔利用はfaceBoundsの有無のみであり、他の用途（角度・ベクトル・表示）への流用はない
  - 結果合成式はposeResult優先であり、姿勢観測が1件でもあれば顔結果は破棄される
  - extractPoseFrameはminimumConfidence 0で呼ばれ、観測1件につき必ずPoseFrameを返す。poseResultがnilになるのは姿勢観測ゼロ件の場合のみである
  - 呼び出し元はcaptureOutputのみであり、detectionQueue上で同期実行後にMainActorへhopしてprocessDetectionへ渡す
  - processDetectionは.pose／.personOnly／.absentの3経路を処理し、肩欠測デバウンス・人物不在デバウンス・校正／監視遷移を持つ
- **Implications**: 姿勢フェーズで観測ゼロ件の場合のみ顔フェーズを実行すれば、合成結果は現行と同一になる。呼び出し側の変更は不要である

### 依存関係の確認

- **Context**: 新規依存の要否と既存契約の互換性を確認した
- **Sources Consulted**: プロジェクト構成（サードパーティなし方針）、roadmap制約（新規依存なし）
- **Findings**:
  - 使用枠組みはVisionとAVFoundationのみで変わらない
  - detectの署名（sampleBuffer・orientation・戻り値Detection）は変更不要である
  - 計測はプロセス内メモリのみで行い、永続化・送出は行わない
- **Implications**: 新規依存なし。公開契約の変更なし。vision-fps-throttleとmainactor-throttleへの前提破壊なし

### 結合リスクの評価

- **Context**: 既存機能への影響と検証観点を洗い出した
- **Sources Consulted**: nekoze-fix requirements §3.4・§4、roadmap共有シーム定義
- **Findings**:
  - 姿勢エラー時のコールバックはposeResultをnilのまま返すため、顔フェーズへ自然に遷移し現行の顔フォールバックと一致する
  - handler.perform例外時は.absentを即返す現行則を維持する
  - 複数人時の中央選択は姿勢側と顔側で独立にmin選択しており、フェーズ分割後も各側の選択則は不変である
  - 計測用カウンタは@unchecked SendableなPoseDetectorに置くため、排他制御が必要である
- **Implications**: 意味保存のための分岐条件は観測有無のみとし、信頼度や点数は持ち込まない。計測は錠付きの小構造体に隔離する

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| 二段階perform | 姿勢のみ実行し、観測ゼロ件時のみ顔のみ実行する | 合成結果が現行と同一、呼び出し側無変更、削減が最大 | perform呼び出しが最大2回になる（失敗経路のみ） | 現行のposeResult優先順序と一致するため採用 |
| 単一perform＋結果破棄 | 現行通り両方実行し、姿勢有効時に顔結果を捨てる | 変更が最小 | 推論コストが減らない | 目的に反するため不採用 |
| 検出層での有効点数判定 | キーポイント数や信頼度で顔実行を決める | 削減幅の調整が可能 | Session層の閾値則と二重定義になり意味が変わる | 意味保存に反するため不採用 |

## Design Decisions

### Decision: 有効性の定義は姿勢観測の有無のみとする

- **Context**: 顔フェーズへ進む条件をどこに置くかが意味保存の核心である
- **Alternatives Considered**:
  1. 姿勢観測ゼロ件でのみ顔実行 — 現行合成式と同一
  2. 有効キーポイント数での顔実行 — 削減調整が可能だがSession閾値と競合する
- **Selected Approach**: 姿勢リクエストの観測がゼロ件（poseResultがnil）の場合のみ顔リクエストを実行する。信頼度フィルタや点数判定は持ち込まない。観測あり・4点全nilのPoseFrameも成功経路とみなし顔省略し、.pose経路扱いを維持する（grill Q2・ADR-0021、要件1.4）
- **Rationale**: 現行の合成式はposeResultの有無のみで分岐しており、観測有無条件が現行と同一の出力を保証する唯一の条件である
- **Trade-offs**: 削減率は姿勢観測の有無に連動し、低信頼度点のみのフレームでは顔省略にならない。意味保存を優先し調整幅は下流specに委ねる
- **Follow-up**: 実装時に両経路の回数を計測し、省略率の実測値を記録する

### Decision: 純ロジック変更に留め、呼び出し側とスレッド構造に触らない

- **Context**: 漸進アプローチの一歩目として変更範囲を最小化する
- **Alternatives Considered**:
  1. PoseDetector内部のみ変更 — captureOutputとprocessDetectionは無変更
  2. 呼び出し側も含めた再配線 — 将来の間引きと同時対応
- **Selected Approach**: PoseDetector内部の実行順序と条件分岐のみを変更する
- **Rationale**: roadmapの共有シーム順序（間引き→条件化→hop削減）に従い、本specは条件化のみを所有する
- **Trade-offs**: FPS制御やhop削減の効果は本specに含まない
- **Follow-up**: 下流specが本specの計測値を前提にできるよう、回数と時間の記録形式を固定する

### Decision: 計測は錠付きの小構造体に隔離する

- **Context**: 成功経路と失敗経路の推論回数・推論時間を実測で裏付ける必要がある
- **Alternatives Considered**:
  1. PoseDetector内に錠付きカウンタ — 変更が局所的
  2. Session層での集計 — 表示と結合するが層をまたぐ
- **Selected Approach**: PoseDetectorが私有の計測値を錠で保護し、読み出し専用の複写を提供する。永続化と送出は行わない
- **Rationale**: 推論の実行点はPoseDetectorであり、計測の所有権を推論点に置くことで取りこぼしがない
- **Trade-offs**: 画面表示や集計UIは本specに含まない。検証はテストと実機計測記録で行う
- **Follow-up**: テストで両経路の計数が進むことを検証する

## Risks & Mitigations

- 姿勢リクエスト失敗時の顔フォールバック漏れ — エラー時はposeResultをnilのまま顔フェーズへ進め、現行と同一の到達性を保つ
- 計測競合による数え漏れ — 錠で保護し、読み出しは複写で行う
- 意味変更の混入 — 分岐条件に信頼度や点数を持ち込まず、観測有無のみとする
- 下流specへの前提破壊 — 公開署名と3値の意味を変えず、計測形式を固定して引き渡す

## References

- nekoze-fix requirements §3.4（人物不在警告）・§4（判定・信頼度閾値・近側選択）
- roadmap（漸進方針・共有シーム順序・実測なき記載禁止）
- NekozeFix/Services/PoseDetector.swift（現行の無条件2リクエスト実行）
- NekozeFix/Session/PostureSessionManager.swift（captureOutput・processDetectionの3経路処理）
- CLAUDE.md Architecture（Types → Domain → Services → Session → UIの依存方向）

## 実測記録（tasks 3.1、ADR 0021 Q9）

- **状態**: 未実施（実機と接続端末が必要な前提であり、simulate では代替しない）
- **手順**: `ios17-baseline` のデバイス検証手順に準拠する。通常姿勢での省略発生と接写俯き等での顔フォールバック発生の双方を実測する
- **記録項目**: 成功経路・失敗経路それぞれの推論回数（`faceSkippedCount`・`faceExecutedCount`）・推論時間（`poseTotalTime`・`faceTotalTime`）と入力FPSとの独立確認のみ。省電力率・持続時間の未実測記載は禁止
- **結果**:

| 経路 | 回数 | 累積推論時間 | 備考 |
|------|------|--------------|------|
| 成功経路（顔省略） | 未計測 | 未計測 | 通常姿勢で計測すること |
| 失敗経路（顔実行） | 未計測 | 未計測 | 接写俯き等で計測すること |

- **下流引き渡し**: 計測後に `vision-fps-throttle`・`mainactor-throttle` へ本節を参照引き渡しする
