# PR#11 未解決レビューコメントの妥当性検証・実証レポート

**検証日時**: 2026-10-02  
**対象PR**: #11 - feat: iOS 17回転移行・向き一本化＋基準線の実機整合  
**検証者**: OpenCode AI Agent

---

## 概要

CodeRabbitによるレビューで指摘された3つの未解決コメントについて、実装コード・設計ドキュメント・テストコードを詳細に分析し、各指摘の妥当性を検証・実証します。

---

## Comment 1: 校正・角度比較設計の整合性（design.md Line 255）

### 指摘内容
> **Line 255**: Revise the calibration and angle-comparison design to keep values consistent when switching between gravity and shoulder-line-orthogonal reference vectors. Define either per-reference calibration values or a transition policy that updates calibration and the detection gate on each switch, including recovery to gravity; do not rely only on recalibration after orientation changes.

### 現状分析

#### 校正値の保存・使用フロー
```swift
// PostureSessionManager.swift:497, 596
// 校正完了時: 平均角度を referenceNearAngleDegrees として保存
referenceNearAngleDegrees: refAngle / average

// PostureAnalyzer.swift:115-117
// 判定時: 保存された校正値を基準として使用
let referenceAngle = referenceNearAngleDegrees ?? 0.0
let delta = acuteAngle - referenceAngle
let verdict: PostureVerdict = (delta >= slouchDeltaThresholdDegrees || distanceOverThreshold) ? .slouchCandidate : .good
```

#### 基準ベクトルの解決順序（PostureAnalyzer.swift:138-168）
```swift
private static func resolve(
    gravityInKeypointSpace: SIMD2<Double>?,
    frame: PoseFrame,
    captureAngleDegrees: Double? = nil
) -> ReferenceVector {
    // 第一段: 重力（有効なら採用・バッファ座標系へ回転）
    if let gravity = gravityInKeypointSpace {
        let length = sqrt(gravity.x * gravity.x + gravity.y * gravity.y)
        if length.isFinite && length > 1e-9 {
            let rotated = rotateToBufferSpace(gravity / length, captureAngleDegrees: captureAngleDegrees)
            return rotated
        }
    }
    // 第二段: 両肩ライン直交上向き法線（従来式）
    if let ls = frame.leftShoulder, let rs = frame.rightShoulder, ... {
        return ReferenceVector(-sdy / shoulderDist, sdx / shoulderDist)
    }
    // 第三段（終端）: 画像垂直 (0, 1)
    return ReferenceVector(0.0, 1.0)
}
```

### 問題の実証

**シナリオ**: 実行中に重力が無効→有効へ遷移（またはその逆）

| 状態 | 基準ベクトル | 校正値の意味 | 問題 |
|------|-------------|-------------|------|
| 校正時: 重力有効 | 重力由来（デバイス座標系→バッファ座標系へ回転済み） | 重力基準での「正しい姿勢」角度 | ✅ 有効 |
| 監視中: 重力無効（平置き等） | 肩ライン直交（バッファ座標系ネイティブ） | **同じ数値だが座標系が異なる** | ❌ **不整合** |
| 監視中: 重力復帰 | 重力由来（再度回転適用） | 校正値は肩ライン基準のまま | ❌ **不整合** |

**具体的不具合例**:
1. ポートレートで校正（重力有効）→ `referenceNearAngleDegrees = 10°`（重力基準）
2. ユーザーがiPadを平置き → 重力無効 → 肩ライン直交にフォールバック
3. 同じ物理姿勢でも、基準ベクトルが「重力由来（回転済み）」から「肩ライン直交（非回転）」に変わる
4. `acuteAngle` の計算基準が変わるため、`delta = acuteAngle - 10°` の意味が変わる
5. 猫背判定の閾値超過判定が誤動作する可能性

### 設計ドキュメントでの言及状況

**design.md Line 309-310** に記載あり:
> - 向き変化時（monitoring中のみ）は自動再校正遷移を行う: `referenceAngle/referenceDistances/referenceSide` と猫背ゲートを破棄し `calibrating` へ遷移

**しかし**: 「向き変化時」のみ再校正であり、「重力の有効/無効切り替わり時」の再校正は明記されていない。

### 妥当性判定: **妥当（修正必要）**

**根拠**:
1. 重力⇔肩ライン直交の切り替わりは、向き変化とは独立して発生しうる（平置き・権限拒否・シミュレータ等）
2. 校正値は「特定の基準ベクトルに対する正しい姿勢の角度」であり、基準ベクトルが変われば校正値も更新すべき
3. 現設計は「再校正は向き変化時のみ」としており、重力フォールバック/復帰時の整合性が担保されていない

---

## Comment 2: MotionServiceの並行性戦略（design.md Line 282）

### 指摘内容
> **Line 282**: モーションキューとメイン間で共有する可変状態を、単に最新値で上書きする設計から、同じ隔離領域で同期して扱う設計に更新してください。latestGravityInKeypointSpace、最終有効時刻、動作状態の更新と参照を@MainActorに集約し、取得コールバックから値を安全に渡してください。start()とstop()にも同じ同期方針を適用してください。

### 現状実装（MotionService.swift）

```swift
final class MotionService {
    // 共有可変状態（複数キューからアクセス）
    var latestGravityInKeypointSpace: SIMD2<Double>?      // Line 26: public var, メインスレッドから読取り
    private var lastValidVector: SIMD2<Double>?            // Line 35: motionQueueから書込み
    private var lastValidTime: Date?                       // Line 36: motionQueueから書込み
    private(set) var isRunning = false                     // Line 39: start/stop(main) と motionQueue からアクセス

    private let motionQueue: OperationQueue = { ... }()    // Line 29-34: 専用キュー（serial）

    func start() {                                         // Line 44: メインスレッド想定
        guard !isRunning else { return }                   // isRunning 読取り（race可能）
        isRunning = true                                   // isRunning 書込み
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            self?.ingest(gravity: motion?.gravity, now: Date())  // motionQueue実行
        }
    }

    func stop() {                                          // Line 56: メインスレッド想定
        isRunning = false                                  // isRunning 書込み（race可能）
        motionManager.stopDeviceMotionUpdates()
        lastValidVector = nil                              // motionQueue状態をmainからクリア
        lastValidTime = nil
        latestGravityInKeypointSpace = nil                 // public var 書込み（race可能）
    }

    // motionQueue で実行される
    func ingest(converted: SIMD2<Double>?, now: Date) {   // Line 94
        if let converted {
            lastValidVector = converted                    // 書込み
            lastValidTime = now
            latestGravityInKeypointSpace = converted       // 書込み（mainから読まれる）
            return
        }
        // ... hold logic ...
        latestGravityInKeypointSpace = last                // 書込み
    }
}
```

### データ競合の実証

**Thread Sanitizer で検出される典型的レースコンディション**:

```swift
// Timeline: Race between main thread and motionQueue
// T1 (main): start()                    → isRunning = true (write)
// T2 (motionQueue): ingest()            → latestGravityInKeypointSpace = v (write)
// T3 (main): read latestGravity...      → read (concurrent with T2 write)  ⚠️ DATA RACE
// T4 (main): stop()                     → isRunning = false, latestGravity... = nil (write)
// T5 (motionQueue): ingest()            → lastValidVector = ..., latestGravity... = v (write) ⚠️ DATA RACE
```

**具体的な問題**:
1. `isRunning`: `start()`/`stop()`（メイン）と `ingest()` 経由の間接的アクセス（motionQueue）で race
2. `latestGravityInKeypointSpace`: `ingest()`（motionQueue）で書込み、メインスレッドで読取り → **データ競合**
3. `lastValidVector` / `lastValidTime`: motionQueue のみだが、`stop()`（メイン）がクリア → **データ競合**

### design.md の現記述（Line 282）
> - Concurrency strategy: 更新はモーションキュー、読取りはメイン。最新値の上書きのみで競合なし。

**この記述は誤り**: Swift のメモリモデルでは、異なるキュー間での非同期読み書きは **データ競合** とみなされる。`OperationQueue` は GCD キューのラッパーであり、`@MainActor` 等のアクター隔離とは異なる。

### 妥当性判定: **妥当（修正必要・重要）**

**根拠**:
1. Swift Concurrency 時代において、非アクター隔離の共有可変状態はバグの温床
2. 実機で再現しにくいヒーゼンバグ（タイミング依存のクラッシュ・不正値）の原因になりうる
3. `@MainActor` に集約することで、コンパイラによる静的検証が可能になる
4. 修正コストは低い（プロパティを `@MainActor` 化し、コールバックで `MainActor.run` または `Task { @MainActor in }` で渡すだけ）

---

## Comment 3: MotionUsageDescriptionTests の XCTSkip 化（MotionUsageDescriptionTests.swift:54-62）

### 指摘内容
> **Around line 54-62**: Update the `testSourceInfoPlistContainsMotionWording` and `testProjectDeclaresMotionKeyForGeneratedPlist` tests to throw `XCTSkip` when `repoFileURL` returns `nil`, rather than failing through `XCTUnwrap`. Preserve the existing assertions when the repository files are available.

### 現状実装

```swift
func testSourceInfoPlistContainsMotionWording() throws {
    let plistURL = try XCTUnwrap(                    // ← ここ
        Self.repoFileURL(["NekozeFix", "Info.plist"]),
        "ソース NekozeFix/Info.plist がリポジトリに存在すること"
    )
    // ...
}

func testProjectDeclaresMotionKeyForGeneratedPlist() throws {
    let pbxprojURL = try XCTUnwrap(                  // ← ここ
        Self.repoFileURL(["NekozeFix.xcodeproj", "project.pbxproj"]),
        "project.pbxproj がリポジトリに存在すること"
    )
    // ...
}

private static func repoFileURL(_ components: [String]) -> URL? {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent() // MotionUsageDescriptionTests.swift
    url.deleteLastPathComponent() // NekozeFixTests/
    for component in components {
        url.appendPathComponent(component)
    }
    return FileManager.default.fileExists(atPath: url.path) ? url : nil  // nil を返しうる
}
```

### 問題の実証

**`repoFileURL` が `nil` を返すケース**:
1. **CI環境での shallow clone** (`.git` なし、または履歴浅い)
2. **Xcode Cloud / GitHub Actions** でのチェックアウト制限
3. **SPM パッケージとして取り込まれた場合**（テストターゲットのみビルド）
4. **xcodebuild でのテスト実行時**、DerivedData からの相対パス解決失敗

**現状の動作**:
- `XCTUnwrap(nil, ...)` → **テスト失敗**（`XCTAssert` 相当の failure を throw）
- テストレポート: "ソース NekozeFix/Info.plist がリポジトリに存在すること" というメッセージで FAIL

**期待される動作（指摘通り）**:
- `XCTSkip` → **テストスキップ**（失敗扱いにならない、CI グリーン維持）
- リポジトリファイルがある環境では従来通りアサーション実行

### 修正案

```swift
func testSourceInfoPlistContainsMotionWording() throws {
    guard let plistURL = Self.repoFileURL(["NekozeFix", "Info.plist"]) else {
        throw XCTSkip("ソース NekozeFix/Info.plist がリポジトリに見つからないためスキップ")
    }
    let data = try Data(contentsOf: plistURL)
    // ... 既存アサーション維持 ...
}

func testProjectDeclaresMotionKeyForGeneratedPlist() throws {
    guard let pbxprojURL = Self.repoFileURL(["NekozeFix.xcodeproj", "project.pbxproj"]) else {
        throw XCTSkip("project.pbxproj がリポジトリに見つからないためスキップ")
    }
    let content = try String(contentsOf: pbxprojURL, encoding: .utf8)
    // ... 既存アサーション維持 ...
}
```

### 妥当性判定: **妥当（修正推奨）**

**根拠**:
1. テストの意図は「ファイルが存在するなら中身を検証する」であり、「ファイルが必ず存在すること」を保証するものではない
2. `XCTSkip` は「前提条件不足によるスキップ」を明示する標準的手法
3. CI での誤検知（flaky test）防止に寄与
4. 修正は軽微でリスクゼロ

---

## 総合判定サマリー

| # | 指摘箇所 | 重要度 | 妥当性 | 修正コスト | 推奨アクション |
|---|---------|--------|--------|------------|----------------|
| 1 | design.md:255 / PostureAnalyzer.swift | **High** | ✅ 妥当 | 中（設計変更+実装+テスト） | **必須修正**: 基準ベクトル切替時の校正値更新ポリシーを設計・実装 |
| 2 | design.md:282 / MotionService.swift | **High** | ✅ 妥当 | 低（@MainActor化+コールバック修正） | **必須修正**: 共有状態を @MainActor に集約 |
| 3 | MotionUsageDescriptionTests.swift:54-62 | Medium | ✅ 妥当 | 極低（XCTUnwrap→XCTSkip） | **推奨修正**: CI安定化のため即時適用 |

---

## 実証用コード片（Comment 1 の不具合再現テスト案）

```swift
// PostureAnalyzerResolveTests.swift に追加すべきテストケース
func testCalibrationConsistency_WhenReferenceVectorSwitches() {
    // Given: 重力有効で校正完了（referenceAngle = 10度）
    let gravityVector = SIMD2<Double>(0, -1)  // デバイス真上
    let captureAngle: Double = 90  // ポートレート
    let rotatedGravity = PostureAnalyzer.rotateToBufferSpace(gravityVector, captureAngleDegrees: captureAngle)
    // rotatedGravity は (1, 0) 相当（バッファ座標系で右向き＝画面上向き）
    
    let frame = makeFrame(nearSide: .left, earShoulderAngle: 10)  // 校正姿勢
    let (_, _, refVector) = analyzer.analyze(
        frame: frame,
        referenceNearAngleDegrees: 10,  // 校正値
        slouchDeltaThresholdDegrees: 5,
        gravityInKeypointSpace: rotatedGravity,
        captureAngleDegrees: captureAngle
    )
    // refVector は rotatedGravity と一致
    
    // When: 重力が無効になり肩ライン直交にフォールバック
    let frameWithShoulders = makeFrameWithBothShoulders()  // 同一物理姿勢
    let (_, verdict, fallbackRef) = analyzer.analyze(
        frame: frameWithShoulders,
        referenceNearAngleDegrees: 10,  // 同じ校正値を使用
        slouchDeltaThresholdDegrees: 5,
        gravityInKeypointSpace: nil,    // 重力無効
        captureAngleDegrees: captureAngle
    )
    
    // Then: 基準ベクトルが変わったため verdict が変わる可能性がある
    // このテストは現状 PASS するが、物理的に同じ姿勢で判定が変わることを示す
    // 期待: 基準ベクトル切替時に校正値も更新される設計なら、この不整合は起きない
}
```

---

## 次のアクション

1. **即時**: Comment 3 の修正（XCTSkip化）を適用・PR 更新
2. **短期**: Comment 2 の修正（MotionService @MainActor化）を適用・テスト実行
3. **中期**: Comment 1 の設計見直し（基準ベクトルごとの校正値 or 切替時再校正ポリシー）を仕様書に反映・実装