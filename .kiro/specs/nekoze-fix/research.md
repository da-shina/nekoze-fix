# Research Log: nekoze-fix

## Discovery Scope

フルディスカバリ（新規機能）。Apple Vision Framework、AVFoundation、SwiftUI、AVAudioSession に関する外部調査を実施。プロジェクト内のADR（0001〜0007）を分析し、既存の設計決定を統合。

## Investigations

### 1. Apple Vision Framework — VNDetectHumanBodyPoseRequest

**Sources**: Apple Developer Documentation, WebSearch

**Findings**:
- `VNDetectHumanBodyPoseRequest` は iOS 14+ から利用可能。`VNHumanBodyPoseObservation.JointName` の個別プロパティも iOS 14+ で定義済み
- 18点のキーポイントを検出：nose, neck, leftEye, rightEye, leftEar, rightEar, leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist, root, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
- キーポイントごとに confidence (0.0-1.0) を返す。低信頼度のキーポイントは結果から省略される場合がある
- パフォーマンス：640x480入力でA17 Proクラスの場合30-50msレイテンシ。ANE/GPUで実行。リアルタイム30fps達成可能
- 極端な頭の角度、部分的な遮蔽、オフセンターのカメラ位置では精度が低下
- 斜め角度では遠側の耳・肩の信頼度が低下する

**Implications**:
- 本アプリの要件（耳・肩の検出）は Vision API で完全にカバー可能
- confidence < 0.5 のフィルタリングは検出後ハンドラで実装する必要がある（API側に minimumConfidence パラメータなし）
- iOS 16+ の要件に対して互換性問題なし

### 2. AVFoundation — フロントカメラパイプライン

**Sources**: Apple Developer Documentation, WebSearch

**Findings**:
- セッションプリセット：`.medium` または `.hd1920x1080` が姿勢検出に適切。Vision Frameworkは4K解像度を必要としない
- フロントカメラ選択：`AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)`
- `AVCaptureVideoDataOutput` をバックグラウンドのDispatchQueueで処理
- デバイス回転時：`connection.videoOrientation` を `AVCaptureVideoOrientation(deviceOrientation:)` で更新
- ライフサイクル：`startRunning()`/`stopRunning()` はバックグラウンドキューで実行（ブロッキング操作）
- バックグラウンド移行時：`UIApplication.didEnterBackgroundNotification` でセッション停止、フォアグラウンド復帰時：`UIApplication.willEnterForegroundNotification` で再開

**Implications**:
- `.medium` プリセットで十分な品質とバッテリー効率を確保可能
- デバイス回転時のビデオオリエンテーション更新は必須

### 3. SwiftUI 統合パターン

**Sources**: Apple Developer Documentation, WebSearch

**Findings**:
- `AVCaptureVideoPreviewLayer` は `UIViewRepresentable` でSwiftUIに統合
- リアルタイムポーズデータの共有：`@Observable` または `ObservableObject` + `@Published`
- Vision リクエストはバックグラウンド DispatchQueue で実行し、UI更新は `DispatchQueue.main.async` で dispatch
- iOS 17+ では `@Observable` マクロが利用可能だが、iOS 16 下限の場合は `ObservableObject` を使用

**Implications**:
- iOS 16+ サポートのため `ObservableObject` + `@Published` パターンを採用
- カメラプレビューは UIViewRepresentable ラッパーが必要

### 4. オーディオセッション

**Sources**: Apple Developer Documentation, ADR 0003

**Findings**:
- `AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)` でマナーモードでも音声再生可能
- `.playback` カテゴリはサイレントスイッチを無視する
- 他のアプリがオーディオ使用中の場合：`.duckOthers` オプションで音量を下げて再生可能
- 短い通知音には `AVAudioPlayer` が最適

**Implications**:
- ADR 0003 の方針通り `.playback` カテゴリを採用
- 「うさぎとかめ」の短い通知音はバンドル内の音声ファイルとして再生

### 5. 姿勢検出ベストプラクティス

**Sources**: WebSearch, ADR 0001/0004/0005

**Findings**:
- 耳ー肩角度計算：肩から耳へのベクトルと垂直線のなす角度を `atan2(dx, dy)` で計算
- 閾値は20-30度が一般的だが、本アプリではキャリブレーション値からの相対変化を使用
- 片側のみ検出時：可視側を信頼度ペナルティ付きで使用
- キャリブレーション：5-10秒の「正しい姿勢」を記録し、平均・分散を保存
- デバウンス/スムージング：EMA（指数移動平均）、連続フレーム閾値、ヒステリシス

**Implications**:
- ADR 0001 の方針通り角度ベースの判定を採用
- ADR 0005 の方針通り近側キーポイント中心のロジックを採用
- ヒステリシス（猫背確定への5秒 vs 改善への即時遷移）は要件で既に規定済み

## Architecture Pattern Evaluation

| パターン | 適合度 | 理由 |
|----------|--------|------|
| MVVM | ★★★★★ | SwiftUI + ObservableObject と最適合。View-ViewModel バインディングが自然 |
| Clean Architecture | ★★☆☆☆ | 単一画面アプリには過剰。レイヤーが多すぎる |
| MVC | ★★★☆☆ | Swiftでは非推奨。ViewModel の利点を失う |

**Selected**: MVVM — SwiftUI の宣言的UIと双方向バインディングに最適。コンポーネント数が少ない単一画面アプリに最も適合。

## Design Decisions

### Generalization
- **TimedConditionGate**: キャリブレーション3秒安定と猫背5秒連続検知は「N秒間連続条件満たしで確定」という同じパターン。1つの汎用コンポーネントに統合。

### Build vs. Adopt
- **Apple Vision / AVFoundation / SwiftUI / AVAudioSession**: 全て採用（プラットフォーム標準）
- **角度計算 / 状態管理**: 構築（シンプルなロジック、外部依存不要）
- **通知音ファイル**: 構築（「うさぎとかめ」の短いメロディを自前生成、ADR 0006準拠）

### Simplification
- 画面暗転モードは独立コンポーネントではなく、UI表示状態の1モードとして扱う
- デバイス回転時の一時停止は PostureSessionManager の状態として管理
- サードパーティライブラリは一切使用しない

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Vision API キーポイント信頼度のばらつき | Medium | confidence < 0.5 のフィルタリング + 近側主指標ロジック |
| 斜めカメラでの遠側キーポイント欠落 | Medium | 近側のみで判定続行（要件 3.5 準拠） |
| バッテリー消費（カメラ常時稼働） | High | .medium プリセット + 画面暗転モード + フレームスキップ検討 |
| マナーモード + 他アプリオーディオ競合 | Low | .playback + .duckOthers オプションで対応 |
| VNDetectHumanBodyPoseRequest のiOS版数互換性 | Low | iOS 14+ API のため iOS 16+ 要件でカバー済み |

## Requirements ID Collision

requirements.md では機能要件「8 アプリのライフサイクル」と非機能要件「8 パフォーマンス」がいずれも 8.1 / 8.2 を使う。デザインでは ID を改変せず、トレース表上で「ライフサイクル」と「性能」を併記して区別した。タスク生成時も同様に扱う。


## 第2段: 前出し距離指標（2026-09-13 追加）

### Investigations
- **第1段 DEBUG 実測（iPad 9th 実機、2026-09-13）**: 校正後30秒の 1s-median 揺れ幅 99.87〜100.81%（ノイズ ±1%）。意図的前出しは +11〜15% で3回再現、復帰は毎回 ~100%。S/N 検証 PASS（予測 1.5〜3% を上回る信号）。
- **側固有差の発見**: 当初の段差（106→114%）は近傍側切り替わりによるもの。左右の耳ー肩距離に約8%の固有差があり、距離指標は側をまたいで比較できない。→ FQ1「校正側ロック」の根拠。
- **自然前出し未実測**: 意図的前出しのみの実測のため、しきい値 8%（FQ2 暫定）は検収タスク（FQ8）で最終確認する。

### Design Decisions
- 距離指標は側ロック（FQ1）: `DistanceMetric`（side + referenceDistance）を Session 層が校正完了時に構成し監視中保持。Domain 層の PostureAnalyzer はロック側ペアと基準距離を入力に取る。
- DEBUG 表示（`debugDistanceText`）は判定と無関係な表示専用足場とし、検収後に chore 削除（FQ5）。角度指標導入時の「DEBUG → 検収 PASS → chore 削除」慣例（コミット 8205aba）を踏襲。

---

## Gap Analysis: 前出し距離指標 第2段（2026-09-13、/kiro-validate-gap）

### Requirement-to-Asset Map（実装現状との差分）

| 要件 | 既存資産（第1段で実装済み） | ギャップ |
|------|------------------------------|----------|
| 4.1 角度 OR 距離 | `AngleSample.nearDistance`、`PostureAnalyzer` の `length` 再利用、`referenceDistance` 保存経路、`CalibrationLogic.accumulatedDistances` | **Missing**: `DistanceMetric` 型、`analyze` の距離条件・閾値引数（OR 判定）、`referenceSide`（Types の completed/snapshot 双方）、ロック側ペア距離の選択（現状 DEBUG は近傍側距離で、FQ1 未実装 = 側混在のまま） |
| 4.1 フォールバック | 角度のみ判定は既存 | **Constraint**: 距離スキップは analyzer 側の分岐として新設（Session の sample nil 経路は角度全体スキップで粒度が違う） |
| 4.3 改善即時（有効指標すべて） | `TimedConditionGate`、表示遷移 | **Missing**: OR 結果に紐づく改善条件の検証（Gate は verdict 入力なので変更不要、統合テストのみ） |
| 4.4 距離閾値スライダー | `SettingsStore` の角度クランプ/永続化機構、MonitorView のスライダー雛形 | **Missing**: `slouchDistanceThresholdPercent`（5〜15%）、UI の横並びスライダー |
| 2.3/2.4 校正側切替リセット | 角度>5度リセット機構、`nearSide` ヒステリシス | **Missing**: 側切り替わりリセット（機構は同一、条件1節追加） |
| DEBUG（FQ5） | `debugDistanceText` 表示・1秒窓 | 削除のみ（8.9）。変更不要 |

### Approach Options
- **A. 既存拡張（推奨）**: 全ギャップが design の契約どおり既存5ファイル（Types/Analyzer/CalibrationLogic/SettingsStore/MonitorView/Session）に収まる。新規ファイル不要。層依存 Types→Domain→Session→UI の一方向は破られない（DistanceMetric は Types に置く）
- B. 新規 DistanceAnalyzer コンポーネント: 耳ー肩距離は角度と同じペア・同じループで計算済み（`length`）。分離すると同一キーポイントを2回解決する冗長。棄却
- C. ハイブリッド: 該当なし（A で十分小さい）

### Effort & Risk
- Effort: **S**（タスク 8.1〜8.7、各1〜3時間、新規パターンなし・既存機構の延長）
- Risk: **Low**。唯一の実測不確定要素は自然前出しの伸び幅 → FQ8 の検収タスク（8.8）が閾値調整の逃げ道を確保済み。側切替リセットは角度リセットと同じクラスの変更で回帰面が狭い

### Recommendations
- 方式 A。注意点は1つ: 現 DEBUG 経路（`updateDebugDistance`）は近傍側距離を使っている。8.1 の `AngleSample.nearDistance` を「監視時はロック側」に意味変更すると DEBUG 表示の意味も変わる（校正中は同一側なので実害なし、検収後に削除されるため許容）。検収 8.8 は「8.5 統合後」に実施されるため、ロック側の値を見た状態で閾値判定できる — 順序は正しい
