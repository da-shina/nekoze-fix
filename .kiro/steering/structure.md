# Project Structure

_Last updated: 2026-10-17_

## Architecture: 単方向レイヤード

依存方向は一方向に固定する。左の層は右の層を知らない。図解は `architecture-diagram.md` を参照。

```
Types → Domain → Services → Session → UI
```

- **Types** (`NekozeFix/Types/`): 全層が共有する値オブジェクト・列挙。`SessionSnapshot`、`SessionPhase`、`ReferenceVector`、`MotionUpdateFrequency` など。
- **Domain** (`NekozeFix/Domain/`): 純関数のみ。I/O・状態保持を禁止する。`PostureAnalyzer`（角度計算・近側選択・基準ベクトル解決）、`TimedConditionGate`（連続条件）、`CalibrationLogic`。
- **Services** (`NekozeFix/Services/`): 外部I/Oと端末資源。`CameraSessionManager`、`PoseDetector`、`MotionService`、`AlertPlayer`、`DeviceRotationService`。
- **Session** (`NekozeFix/Session/`): 状態の所有者とオーケストレーション。`PostureSessionManager`（`@MainActor`、状態の唯一の書き込み点）、`FrameThrottle`、`MainHopGate`、`DimPowerPolicy`、`SettingsStore`。
- **UI** (`NekozeFix/UI/`): SwiftUI 画面。`SessionSnapshot` の公開状態だけを購読し、判定・状態を持たない。

**Why**: 層をまたぐ循環依存を防ぎ、Domain をカメラなしで単体検証可能にし、状態の書き込み点を1つに集約して判定の整合性を保つ。

## Directory Organization

機能ではなく**層**で分割する。新しい型・関数はその責務の層に置く。

- 共有の値型を増やすなら `Types/PostureTypes.swift`（単一ファイル）。
- 判定・計算の純ロジックは `Domain/`。I/O が混ざりそうなら Services か Session に置く。
- デバイス資源・外部フレームワークの利用は `Services/`。テスト容易性のため、必要ならプロトコルのシームを切って `Types` に置く。
- 状態遷移・結線・ライフサイクルは `Session/`。小さな純粋方針は値型として切り出す（例: `DimPowerPolicy`）。

## Naming Conventions

- 型: `PascalCase`。プロトコルは役割名（`DeviceRotationServiceProtocol`）。
- メソッド・プロパティ: `lowerCamelCase`。真偽値は `is` / `should` 接頭（`isPersonDetected`、`shouldInfer`）。
- テストクラス: `<対象><観点>Tests`（`DimPowerPolicyTests`）。テストメソッドは `test_<条件>_<期待>`（`testTick_AbsentBeyondThreshold_AdvancesToAbsent`）。
- 通知音・リソース等のファイル名は既存慣例に合わせる。
- ドメイン用語は `CONTEXT.md` の見出し語（英語併記）に一致させる。

## Testing Structure

- `NekozeFixTests/` に対象ごとのテストファイルをフラットに配置。テストダブルは `*TestDouble.swift`。
- Domain は純関数として直接テスト。Services はプロトコルのフェイクを注入。Session は `@testable` で段階・係数を読み、結合挙動を検証する。
- テストは実装詳細ではなく契約（閾値・順序・不変則）を固定する。

## Documentation & Specification

このプロジェクトは Kiro の Spec-Driven Development で進める。Markdown は原則日本語。

- **仕様**: `.kiro/specs/<feature>/`（`spec.json` / `requirements.md` / `design.md` / `tasks.md` / `research.md` / `brief.md`）。`language: ja`。
- **設計判断の根拠**: `design.md` の **Grilling Decisions** と `docs/adr/NNNN-*.md`。閾値・ゲート秒数・再通知間隔・プリセット等の数値はここに定義する。新しい重要判断は新しい ADR を起こし、既存 ADR を安易に改訂しない。
- **用語**: `CONTEXT.md` が用語の唯一の正。コード挙動やパラメータを変えたら design.md / ADR / CONTEXT.md を同期する（git 履歴に docs sync の慣例あり）。
- **ロードマップ**: `.kiro/steering/roadmap.md` が省電力プロジェクトの spec 分解と依存順を保持する。

## Commit Convention

`<type>(<feature>): <要約>` 形式。type は `feat` / `fix` / `docs` / `refactor` / `wip`。feature は spec 名（例: `dim-mode-saving`）。タスク番号があれば要約に含める（例: `feat(dim-mode-saving): 3.1 暗転移行・解除経路への切替え結線`）。
