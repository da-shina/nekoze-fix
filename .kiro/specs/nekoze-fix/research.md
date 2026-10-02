# Gap Analysis: nekoze-fix

## Analysis Summary
- 現在の実装では、両肩検出時に「肩ラインの直交上向き法線」を基準ベクトルとし、片側時は画像下方向 (0,1) を使用している。
- 要件（改訂後）では、「カメラ画像における重力方向（真下）と近側の耳‑肩ベクトルのなす鋭角」を基準角度とすることが明記された。
- ギャップ: 基準ベクトルの算出ロジックを肩ライン法線からデバイスの重力ベクトル（CMotion）に変更し、Vision座標系への座標変換を追加する必要がある。
- 影響範囲: `PostureAnalyzer.analyze` の基準ベクトル計算部および、重力取得のための新しい依存・初期化コード（`PostureSessionManager` や `Services` 配下にモーションサービスを追加）。
- 代替案: 既存の肩ライン法線を保持しつつフォールバックとして重力ベクトルを使用するハイブリッドアプローチも検討可能だが、要件は「真下」を基準と明確にしているため、完全置換が望ましい。
- 調査が必要な点: 
  1. `CMMotionManager` の利用許可とバッテリー影響。
  2. デバイスの向き（ポートレート/ランドスケープ、ミラーリング）に応じた重力ベクトルのVision座標系への変換ロジック。
  3. モーションデータの取得頻度と遅延（カメラフレームとの同期）。
  4. 重力取得不可（シミュレータ等）時のフォールバック戦略（既存肩ライン法線に戻す）。

## Detailed Findings

### 1. 現行実装の構造
- **Domain層**: `PostureAnalyzer.analyze` が姿勢フレームから角度と判定を出す。基準ベクトルは `perpX, perpY` で算出（肩ライン直交上向き）。
- **Session層**: `PostureSessionManager` が `@MainActor` でカメラセッションとスナップショット管理。現在ではモーション取得は行っていない。
- **Services層**: カメラ、姿勢検出、音声、端末向き監視などがあるが、モーションサービスは存在しない。

### 2. 要件との比較
| 要件項目 | 現行実装 | ギャップ |
|----------|----------|----------|
| 4.1 基準姿勢の角度定義 | 肩ライン直交上向き法線（両肩時）／画像下方向（片側時） | 重力方向（真下）と耳‑肩ベクトルのなす鋭角 |
| カメラ設置角度の吸収 | キャリブレーションで参照角度を保存し、その角度を基準とする | 重力ベクトルはデバイス姿勢に依存するため、キャリブレーション不要で真下が得られるが、デバイス取り付け角度は依然として考慮必要（デバイスの傾きは重力に反映） |
| 信頼度フィルタ | 0.5 未満除去（要件では 0.3 に変更済み） | 一致させる必要あり（現行は 0.5） |

### 3. 実装オプション
#### オプションA: 完全置換（推奨）
- `PostureAnalyzer.analyze` の基準ベクトル計算を削除し、`CMDeviceMotion.gravity` から取得した重力ベクトルをVision座標系に変換した単位ベクトルを使用。
- 片側時も同じ重力ベクトルを使用（フォールバック不要）。
- 必要な変更点:
  1. `Services/MotionService.swift` 新規作成（`CMMotionManager` ラップ）。
  2. `PostureSessionManager` に `MotionService` への参照を持ち、最新の重力ベクトルを提供するプロパティを追加。
  3. `PostureAnalyzer.analyze` のシグニチャに `referenceGravityVector: CGVector?` （または `simd_float2`）を追加。
  4. 基準ベクトルが `nil` の場合は従来の肩ライン法線にフォールバック（安全策）。
  5. `Info.plist` に `NSMotionUsageDescription` を追加。

#### オプションB: ハイブリッド（肩ライン優先＋重力補助）
- 基本は現行の肩ライン法線を使用し、重力ベクトルを利用して肩ラインのズレを補正する。
- 実装コストは低いが、要件の「真下」基準からは逸脱。
- 要件記述を変更する必要があるため非推奨。

#### オプションC: モーションデータを使わずに既存ロジック改善のみ
- ギャップを埋めず、現行の肩ライン法線のままとする。
- 要件不適合。

### 4. 外部依存・リサーチ課題
- **Core Motionの利用可否**: iOS 16+ で利用可能。シミュレータでは重力が (0,0,-1) 固定になるため、テスト時にフォールバックが働くことを確認必要。
- **座標変換**: 
  - `CMDeviceMotion.gravity` はデバイスの本体座標系（x: 右、y: 上、z: 前）で返される。
  - Visionの座標系は画像左上が原点、x 右、y 下。
  - `AVCaptureVideoDataOutput` から取得できる `rotation`（0, 90, 180, 270）および `isMirroring`（フロントカメラは true）を考慮したアフィン変換が必要。
- **バッテリー影響**: `deviceMotionUpdateInterval` を 1/30 程度に抑えれば、カメラフレームと同等のオーバーヘッドで済むと考えられる。

### 5. テスト観点
- ユニットテスト: `PostureAnalyzer` に重力ベクトルをモックとして注入し、既知の角度が正しく出力されるか。
- 結合テスト: 実際のデバイスで様々な傾け方・姿勢で判定が安定するか。
- フォールバックテスト: モーション取得失敗時に既存ロジックに戻るか。

## Conclusion
ギャップは「基準ベクトルを重力方向に変更する」一点に集約される。実装コストは中程度だが、要件に準拠し、姿勢判定の頑健性（デバイスの微小傾きに対する免疫）を大きく向上させる。オプションA（完全置換、フォールバックあり）を設計フェーズで採用することを推奨する。

---
*分析完了: 2026-09-27*

---

# Gap Analysis追記: 重力基準一本化（2026-09-28改訂対応）

## 1. Current State Investigation

- **Domain層**: `NekozeFix/Domain/PostureAnalyzer.swift` は純粋関数 `analyze(frame:referenceNearAngleDegrees:slouchDeltaThresholdDegrees:distanceMetric:slouchDistanceThresholdPercent:previousNearSide:)`。基準ベクトル `perpX/perpY` を両肩ライン直交（両肩時）／`(0,1)`（片側時）で算出（69〜92行目）。重力入力なし。`isValidPair` は `minimumKeypointConfidence = 0.3`（`Types/PostureTypes.swift:133`）準拠だが、コメントに旧 `0.5` 表記が残る軽微な不整合あり。
- **Session層**: `NekozeFix/Session/PostureSessionManager.swift` は `@MainActor`。`cameraManager/poseDetector/postureAnalyzer/calibrationLogic/settingsStore/orientationMonitor/alertPlayer` を所有し、モーション参照なし。`processDetection`（254〜303行目）で `analyze` を重力なしで呼ぶ。`videoAspectRatio`・EMA平滑・`personMissing/shoulderMissing` 猶予（各0.5秒）は実装済み。
- **Services層**: `Camera/ PoseDetector/ AlertPlayer/ DeviceOrientationMonitor` の4件。`MotionService` 不存在。`DeviceOrientationMonitor` は `currentVideoOrientation/isRotating`（5秒タイマ）を発行するが、`PostureSessionManager` は向きのみ購読し `isRotating` による判定停止配線はない（回転中停止の要件7.2に対する配線ギャップは既存のまま）。`captureOutput` は Vision に `.up` 固定で渡す（iPadOS 18自動回転の注記あり、227〜244行目）。
- **UI層**: `UI/PostureOverlayView.swift referenceArc`（80〜127行目）は両肩画面座標から肩ライン直交の緑線を描画。重力線の描画なし。`normalizePoint` の AspectFit 補正は重力線にも同一適用が必要。
- **Types層**: `AngleSample/DistanceMetric/PoseFrame/Keypoint` は変更不要。重力型の定義なし。
- **権限・設定**: `NekozeFix/Info.plist` は `NSCameraUsageDescription` のみ。`NSMotionUsageDescription` なし（`project.pbxproj` もカメラのみ）。モーション権限要求コードなし。
- **テスト**: `PostureAnalyzerTests`（20件超）が重力なし署名に固定。肩ライン直交の期待値（例: `testAngleCalculation_TiltedShoulders...` は直交基準で0度）が重力化で反転する。`CalibrationLogicTests/DistanceMetricIntegrationTests/PostureSessionManagerTests` は `AngleSample` 経由のため署名影響は小さいが、角度分布変化の再検証が必要。
- **文書**: `design.md` は重力＋`MotionService` を先行記述（未実装）。`CONTEXT.md` と ADR-0017/0008-superseded は2026-09-28 grill で更新済みのため用語ギャップは解消、コードギャップのみ残存。
- **Steering**: `.kiro/steering/` に `product.md/tech.md/structure.md` なし（警告: プロジェクト文脈が不足し、本分析はコード実測＋要件＋ADRのみを根拠とする）。

## 2. Requirements Feasibility Analysis（Requirement-to-Asset Map）

| 要件 | 既存資産 | ギャップ |
|------|----------|----------|
| 4.1 主基準＝近側肩点起点の天方向線と肩→耳ベクトルの鋭角0〜90度、両肩有無で一本化 | `PostureAnalyzer` 肩ライン直交／`(0,1)` | Missing: 重力→画像座標投影ベクトルを第一基準にする算出ロジック。両肩時の分岐削除 |
| 4.1 代替＝重力不能時は肩ライン直交で継続 | 上記分岐（現主基準）が流用可能 | Missing: 切替条件・復帰の配線。秒数・ヒステリシスは設計委譲（grill Q7=A）のため要件側は確定済み |
| 4.1 最終代替＝両方不可時は画像垂直 | 片側時 `(0,1)` と等価 | Missing: 三段フォールバック鎖（重力→肩直交→画像垂直）の明示化。現コードは二段 |
| 4.8 天方向基準線の表示・校正の一貫性、代替中は通常と同じ見た目・区別なし | `PostureOverlayView.referenceArc` 肩直交描画 | Missing: 重力線描画＋代替時の無区別表示（判定と同一ベクトル使用）。色・太さ変更なし |
| 2.7／4.8 校正は天方向基準で登録、閾値・秒数不変（5秒・5度・7窓） | `CalibrationLogic` は `nearAngleDegrees` をそのまま蓄積 | Constraint: ロジック変更不要だが、角度分布変化によりリセット頻発の可能性。実機再検証が必要 |
| 4.6 近側＝x＋ヒステリシス維持、4.x 距離OR不変 | 現行通り | Gapなし（回帰防止のみ） |
| 7.2 回転中は判定一時停止を維持 | `isRotating` 発行あり・判定停止配線なし | Constraint: 重力化と独立の既存ギャップ。今回悪化しないが改善もしない |
| Adjacent 傾き計測依存・拒否でも黙って代替継続、監視を妨げない | 権限コード・文言なし | Missing: `NSMotionUsageDescription`＋黙過フォールバック（ブロッキング案内なし） |

## 3. Implementation Approach Options

### Option A: 既存拡張（analyzer に重力注入＋MotionService 追加）
- `Services/MotionService.swift` 新規（`CMMotionManager` ラップ、最新重力＋Vision座標変換を公開）。
- `PostureAnalyzer.analyze` に `gravityInVision: SIMD2<Double>?`（または `CGVector?`）引数追加。`nil` または変換失敗時は既存 `perp` 算出へフォールバックし三段鎖にする。純粋性維持（マネージャを直接参照しない）。
- `PostureSessionManager` が MotionService を所有し毎フレーム最新値を注入。`Info.plist`＋`project.pbxproj` にモーション文言追加。`PostureOverlayView` に重力ベクトル入力追加（通常と同じ見た目）。
- Trade-offs: ✅ 最小ファイル数・既存テスト流用しやすい／❌ `analyze` の引数増・循環的複雑度増、座標変換が Domain に漏れる恐れ。

### Option B: 新規分離（ReferenceVectorResolver を新設）
- `Domain/ReferenceVectorResolver.swift` 新規に三段解決（重力→肩直交→画像垂直）を集約し、解決結果（ベクトル＋出所）を返す。`PostureAnalyzer` は解決済みベクトルを受け取るのみ。`MotionService` は Services に新設。
- Trade-offs: ✅ SRP維持・単体テスト容易（resolver の表駆動テストが書ける）／❌ ファイル増・インターフェース設計が必要、既存テストの書換え範囲はAと同等。

### Option C: ハイブリッド（推奨の土台、段階実装）
- Phase 1: A で最小接続（MotionService＋注入＋plist＋overlay＋フォールバック鎖＋既存テスト更新）。
- Phase 2: 変換・解決ロジックを Resolver へ抽出、デバウンス（切替振動対策）・回転過渡扱い・実機検証を反映。
- Trade-offs: ✅ 反復的に洗練でき、grill 残件（猶予秒数・回転5秒タイマとの干渉）を設計で吸収できる／❌ 計画が二段階になり Phase 1/2 の境界管理が必要。

## 4. Effort & Risk

- Effort: **M（3〜7日）**。新規パターン（Core Motion＋座標変換）が1件あるが、アーキテクチャ変更なし・影響ファイルは特定済み（analyzer/session/overlay/plist/tests）。
- Risk: **Medium**。変換行列（前後カメラ・縦横・ミラー）と切替振動・シミュレータでの重力欠測の扱いは実機検証が必須だが、フォールバック鎖により安全側に倒れる。

## 5. Recommendations for Design Phase

- 推奨は Option C（Phase 1＝A、Phase 2＝B抽出）。純粋性制約（analyzer にマネージャを持ち込まない）と無区別表示（Q9）・黙過フォールバック（Q10）を設計制約として固定する。
- Research Needed（設計で詰める）: (1) デバイス→Vision 変換行列の全組合せ（front/back × portrait/landscape × mirror）と `.up` 固定パイプラインとの整合、(2) モーション取得間隔・遅延と映像フレームの同期方式（最新値注入 vs タイムスタンプ補間）、(3) 切替デバウンス値と復帰即時性の決定（personMissing 0.5秒前例との整合）、(4) シミュレータ・権限拒否時のテスト戦略（モック重力の注入経路）、(5) `isRotating` 5秒タイマと重力投影の干渉確認、(6) 校正 5度閾値の実機再検証要否。

---
*追記分析完了: 2026-09-28（対象: 2026-09-28改訂要件＋grill確定事項 Q1〜Q11 オールA、前回 2026-09-27 分析の後継）*

---

# Design Discovery Log: 重力基準一本化（2026-09-28）

## Summary

- **Feature**: nekoze-fix
- **Discovery Scope**: Extension（既存姿勢検知の基準線変更）
- **Key Findings**:
  - 拡張点は `analyze` 引数注入が自然であり、純粋性制約（Domain は Services 非参照）を満たす
  - プラットフォーム標準の CoreMotion を採用し、自作傾き推定は不採用
  - 校正が定数オフセットを吸収するため変換表の軽微な誤差は致命化しない（直立不変条件テストで検出）

## Research Log

### 拡張点と影響範囲

- **Context**: 基準ベクトル算出の置換に必要なファイル特定
- **Sources Consulted**: `PostureAnalyzer.swift` 69〜92行目、`PostureSessionManager.swift` 254〜303行目、`PostureOverlayView.swift` 80〜127行目、`Info.plist`、テスト群
- **Findings**: 変更は analyzer・session・overlay・plist・テストに限定できる。校正・ゲート・通知は無改修。回転停止配線なしは既存ギャップとして据え置く
- **Implications**: File Structure Plan の新設2件・改修6件に反映

### 重力取得手段の選定

- **Context**: 天方向の取得方式
- **Sources Consulted**: 要件 Adjacent（傾き計測依存）、grill Q1=A（投影方向）、iOS 16+ 制約
- **Findings**: `CMMotionManager.deviceMotion.gravity` が唯一の標準手段。取得間隔 1/30、監視・校正中のみ動作で電池目標を維持できる
- **Implications**: `MotionService` を新設し、取得・変換・保持を一箇所に所有させる

### 座標変換と向き・鏡の扱い

- **Context**: デバイス座標からキーポイント空間への投影
- **Sources Consulted**: `.up` 固定パイプラインの注記（227〜244行目）、`DeviceOrientationMonitor` の向き値、Overlay の `isMirrored`
- **Findings**: 向き・鏡は実行時に読む（決め打ちしない）。z 支配時は無効扱い。同一入力から判定と表示に同一ベクトルを渡すことで一致を保証する
- **Implications**: 変換表＋表駆動テストを設計に規定。P0 検証は縦置き前面に限定する

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| 値注入 | analyzer に重力値を引数追加 | 最小差分、既存テスト流用 | analyzer が膨らむ | Phase 1 に採用 |
| Resolver 分離 | 三段解決を新構造体に集約 | SRP、表駆動テスト容易 | ファイル増 | 同一 spec 内で併用 |
| 新規ゲート型 | 切替デバウンス専用型 | 明示的 | 過剰抽象 | 不採用、保持時間に内包 |

## Design Decisions

### Decision: 三段解決を Resolver に集約し MotionService に保持を持たせる

- **Context**: フォールバック鎖の所有者と振動対策の置き場所
- **Alternatives Considered**:
  1. analyzer 内に直書き — 最小だが責務混在
  2. Resolver＋Motion 保持 — 解決は純粋、時間は取得側
- **Selected Approach**: 2 を採用。無効 0.5 秒保持は MotionService 内定数、復帰即時
- **Rationale**: 既存猶予パターン（各 0.5 秒）との整合、テスト容易性
- **Trade-offs**: 定数は設計値であり要件化しない
- **Follow-up**: 実機での保持時間の妥当性確認

### Decision: 代替中の表示は無区別とする

- **Context**: grill Q9=A
- **Alternatives Considered**:
  1. 同一見た目 — 体験安定
  2. 区別表示 — 精度低下の明示
- **Selected Approach**: 1 を採用。判定と同一ベクトルを描画する
- **Rationale**: 代替は一時的・稀であり通知ノイズを避ける
- **Trade-offs**: デバッグ時の区別はログに寄せる
- **Follow-up**: なし

## Risks & Mitigations

- 変換表の全組合せ誤り — P0（縦置き前面）実機検証＋不変条件テストで緩和
- 校正 5 度閾値の頻発リセット — 実機で要否判断、設計値は不変
- シミュレータ恒常 nil — モック注入経路で単体検証、実機レーン確保

## References

- ADR-0017 重力基準一本化、ADR-0008 superseded 注記
- `.kiro/specs/nekoze-fix/requirements.md` 2026-09-28改訂（4.1、4.8、2.7）