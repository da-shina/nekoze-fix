# 上流受口の実装状態確認記録（tasks 1.1）

- 確認日: 2026-10-16（作業ツリー時点）
- 対象要件: 2.1（暗転時の推論低下）, 3.1（暗転時の取得低下）
- 判定: **GO** — dim 実装に進める（コード実態として全受口が存在する）

## 受口の合否

| # | 受口 | 合否 | 証拠 |
|---|------|------|------|
| 1 | 推論上限変更 `FrameThrottle.setLimit(_:)`（fps側で追加） | PASS | `NekozeFix/Session/FrameThrottle.swift:93`（`mutating func setLimit(_ fps: Double)`）。単体検証あり `NekozeFixTests/FrameThrottleTests.swift:223,239,252,268,283` |
| 2 | センサー頻度設定 `MotionService.setUpdateFrequency(_:)`（motion側） | PASS | `NekozeFix/Services/MotionService.swift:92`。許可値は3値enumに閉じる設計のまま |
| 3 | 頻度候補 `enum MotionUpdateFrequency` | PASS | `NekozeFix/Types/PostureTypes.swift:199`（`thirtyHz` / `fifteenHz` / `tenHz`、`interval`、計測表記 `shortLabel` は `:208`） |
| 4 | 受動公開pull一本化（Sessionが読取る方向のみ） | PASS | 読取り側: `NekozeFix/Session/PostureSessionManager.swift:708`（`motionService.latestGravityInKeypointSpace`）＋ `:709`（`noteConsumption(hasValue:)`）。`MotionService` 側に Session への delegate / callback / publisher は存在しない（サービス内 `Task { @MainActor }` の内部 ingest のみ）。公開値 `latestGravityInKeypointSpace` は `NekozeFix/Services/MotionService.swift:30`、消費記録 `noteConsumption` は `:175` |
| 5 | 起停契約 `setMotionRotationRunning` の不変 | PASS | `NekozeFix/Session/PostureSessionManager.swift:200`（`private func` のまま一本化維持、呼出し6箇所 `:331,344,366,380,395,893`） |

## motion-frequency の完了評価

- コード実態: 上記 #2〜#4 の受口は作業ツリーに実装済み。Session 側の利用（`:708-709` の pull 読取り、`:921` の `setUpdateFrequency` 呼出し）も存在する。
- フラグ実態との差異: `.kiro/specs/motion-frequency/spec.json` は `phase: tasks-generated` / `ready_for_implementation: false` のまま（`vision-fps-throttle/spec.json` も同値）。すなわちコード先行・フラグ未更新の状態であり、本記録はコード実態を優先して GO とする。正式な完了宣言は上流側の更新を待つ。
- 未完了時の待機条件（tasks 1.1「未実装の受口がある場合は先行完了を待つ」）には該当しない。全受口が存在するため待機は不要。

## 適用順の評価（fps→mainactor→motion→dim）

- `git log --oneline -- NekozeFix/Session/PostureSessionManager.swift` の履歴は fps 系（`vision-fps-throttle`）→ mainactor 系（`mainactor-throttle`）→ motion 系（`motion-frequency`）の順に積まれている。
- dim 結線は未適用: `PostureSessionManager.swift` 内に `DimPower` / `setLimit` への参照は存在しない（`enterDimMode` `:421`・`exitDimMode` `:430` は輝度保存・復元と `isDimmed` フラグ更新に閉じる）。dim 関連ファイル（`DimPowerPolicy.swift` 等）は作業ツリー上の未追跡新規であり、コミット履歴には存在しない。
- よって本 spec の Session 編集は適用順の最後となり、調停則（先行3specの結線を削除・移動しない、本 spec 側がリベースする）を満たせる状態である。

## 検証コマンド

- `rg -n "func setLimit" NekozeFix/Session/FrameThrottle.swift` → `93: mutating func setLimit(_ fps: Double) {`
- `rg -n "func setUpdateFrequency|latestGravityInKeypointSpace|noteConsumption" NekozeFix/Services/MotionService.swift` → `:30, :92, :175` を含む13件
- `rg -n "enum MotionUpdateFrequency" NekozeFix/Types/PostureTypes.swift` → `199:enum MotionUpdateFrequency: Double, Equatable {`
- `rg -n "setMotionRotationRunning" NekozeFix/Session/PostureSessionManager.swift` → `:200` 定義＋呼出し6件
- `git log --oneline -5 -- NekozeFix/Session/PostureSessionManager.swift` → motion-frequency の wip を先頭に fps / mainactor / motion の順序を確認
