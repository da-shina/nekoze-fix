# Research & Design Decisions: motion-frequency

---

**目的**: motion-frequency の設計に向けた調査結果・判断根拠・リスクを記録する。

---

## Summary
- **Feature**: `motion-frequency`
- **Discovery Scope**: Extension（既存 MotionService・Session 消費点への局所変更）
- **Key Findings**:
  - 重力の取得（30Hz 固定）・保持（0.5s 単一ホールド）・消費（フレーム処理ごとの最新値読取り）は既に分離されており、変更点は MotionService 内に局在する
  - 変換式は向き非依存（`normalize(−gx, −gy)`）のため、頻度変更は回転・鏡像補正に影響しない
  - 毎サンプルの Main 受け渡しは、同一値の受信時に省略できる余地がある（最新値優先と両立）

## Research Log

### MotionService の現状把握
- **Context**: 変更範囲の特定と既存テストの把握のため、取得・保持・起停の実装を確認した
- **Sources Consulted**: `NekozeFix/Services/MotionService.swift`, `NekozeFixTests/MotionServiceTests.swift`
- **Findings**:
  - 取得間隔は固定値（1/30秒）、直列キュー受信＋毎サンプル Main 受け渡し＋`ingest` 単一入口
  - 無効時の直前有効値保持は 0.5 秒の単一タイマ（最終有効時刻に固定・スライドなし）、回復は即時
  - 起停は `start`・`stop` に一本化され、停止時は保持値を破棄して nil に戻す
  - 既存テストは変換・ホールド境界・平置き無効・起停を固定時刻で検証している
- **Implications**: ホールド則と `ingest` の入口契約は変更せず、既存テストを回帰として維持する。頻度変更によるホールド期限評価の粒度変化は最大で1サンプル周期に収まる

### 重力値の消費点の特定
- **Context**: 更新頻度と利用頻度の独立性を確認するため、判定側の参照方法を調査した
- **Sources Consulted**: `NekozeFix/Session/PostureSessionManager.swift`（`analyze` 呼出し点）, `NekozeFix/Domain/PostureAnalyzer.swift`
- **Findings**:
  - Session はフレーム処理ごとに `latestGravityInKeypointSpace` の最新値を読取り、`analyze` に値渡しする（Analyzer は純関数のため Services を参照しない）
  - nil は代替解決（両肩ライン直交→画像垂直）への合図であり、値以外の入力が同一なら判定は不変
  - 取得側の頻度を下げても消費側の読取り則は変えずに済む（独立化は取得側の変更で完結する）
- **Implications**: 消費点の契約変更は不要。計測カウンタの消費側記録は Session 側の読取り時に付随させる

### 回転・鏡像補正との関係
- **Context**: 頻度変更が回転・鏡像整合を壊さないことを確認するため、向き依存の有無を調査した
- **Sources Consulted**: `NekozeFix/Services/DeviceRotationService.swift`, `NekozeFix/Session/PostureSessionManager.swift`（capture 角補正）, nekoze-fix requirements §4.1・§4.9・§7
- **Findings**:
  - 重力→天方向の変換は向き引数を持たない純粋変換であり、バッファ座標系への回転は Session 側で直近 capture 角により適用される
  - 回転角配信（DeviceRotationService）は重力取得と独立した系統であり、配信方式の変更は不要（整合確認のみ）
  - 回転中の判定一時停止・完了後再開は Session 側の既存則であり、頻度変更の影響を受けない
- **Implications**: 本設計は回転・鏡像系に手を加えず、回帰確認のみを検証計画に含める

### 起停シームと dim-mode-saving との共有
- **Context**:  roadmap 上の共有シーム `setMotionRotationRunning` への影響を確認した
- **Sources Consulted**: `NekozeFix/Session/PostureSessionManager.swift`（起停一本化）, `.kiro/steering/roadmap.md`, brief.md
- **Findings**:
  - 起停は Session 内の単一メソッドに一本化され、監視・校正開始／停止・背景移行／暗転継続の則はここに集約されている
  - dim-mode-saving は本機能の頻度調整の受口を利用する下流であり、起停方針自体の変更は範囲外
- **Implications**: 頻度設定の変更受口を MotionService 側に用意し、起停メソッドの契約は変えない。暗転時の切替方針には触れない

## Architecture Pattern Evaluation
| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| 固定値の直接書換え | 取得間隔の定数を選定値に書換えるのみ | 最小変更、既存テストへの影響なし | dim-mode-saving からの再利用ができない、再選定時に再編集が必要 | 不採用（共有シームの再利用性を欠く） |
| 頻度設定の内部設定化＋単一選定 | 間隔を設定可能な内部状態にし、選定値を既定とする | 単一変更点、受口の再利用可、テスト容易 | 設定範囲の検証が必要 | 採用（最小限の一般化） |
| 適応型自動制御 | 状態に応じた自動頻度切替 | 長時間効果の可能性 | 判定鮮度への影響が未検証、範囲超過（全体適応化は roadmap で見送り） | 不採用（要求 7.2・roadmap の Out に抵触） |

## Design Decisions

### Decision: 取得間隔の内部設定化（既定は現状維持）
- **Context**: 選定と比較・下流からの再利用のため、固定値を設定可能な内部状態にする
- **Alternatives Considered**:
  1. 固定値の直接書換え — 最小だが再利用不可
  2. 内部設定化＋許可値検証 — 単一変更点で再利用可
- **Selected Approach**: 取得間隔を内部で設定可能にし、許可する値は比較候補（毎秒30回・15回・10回）に限定する。既定値は毎秒30回（現状）とし、選定結果の反映は既定値の単一点変更で行う
- **Rationale**: 変更点を MotionService 内に閉じ、既存の起停・保持・変換契約を維持できる
- **Trade-offs**: 許可値検証の追加が必要になるが、範囲は1箇所の検査に収まる
- **Follow-up**: 実装時に許可外値の扱い（既定維持）をテストで確認する

### Decision: ホールド則・変換・代替鎖は不変とする
- **Context**: 要求 5（退行と復帰）および要求 7（適用範囲限定）のため
- **Alternatives Considered**:
  1. 低頻度に合わせた保持期間の延長 — 判定鮮度を損なう恐れがあり不採用
  2. 現行則の維持＋粒度影響の上限評価 — 採用
- **Selected Approach**: 0.5 秒単一ホールド・向き非依存変換・代替鎖の選択則を変更しない。頻度変更による期限評価の粒度変化は最大で1サンプル周期（10Hz 時で 0.1 秒）に収まることを確認条件とする
- **Rationale**: 既存テストをそのまま回帰として利用でき、判定仕様への波及を断てる
- **Trade-offs**: 低頻度時の期限超過が最大 0.1 秒遅延し得るが、3秒確定則に対する影響は無視できる範囲であり回帰で検証する
- **Follow-up**: ホールド境界の既存テストを全頻度条件で再実行する

### Decision: 同一値受信時の受け渡し省略（最新値優先と両立）
- **Context**: 要求 3（独立化と最新値優先・不要な連動更新の抑制）のため
- **Alternatives Considered**:
  1. 全サンプル受け渡しの維持 — 変更なしだが 30Hz 時の受け渡しが残る
  2. 微小差の受信を省略する比較付き受け渡し — 採用（許容差付き比較）
- **Selected Approach**: 受信側で前回受信値との許容差付き比較を行い、実質同一の場合は Main 側への受け渡しを省略する。値が変化した場合と有効・無効の状態が変化した場合は必ず受け渡す
- **Rationale**: 判定側は読取り時に最新値を参照するため、同一値の省略は判定結果に影響しない
- **Trade-offs**: 許容差の選定が必要になるが、変換出力が単位ベクトルであるため固定の微小値で足りる
- **Follow-up**: 許容差の根拠をテストで固定し、状態変化時の受け渡し漏れがないことをテストする

### Decision: 計測カウンタはメモリ内のみ・所有は MotionService
- **Context**: 要求 1（計測と記録）および制約（基準姿勢と同様に永続化しない）のため
- **Alternatives Considered**:
  1. 永続化付き計測 — 制約違反のため不採用
  2. メモリ内カウンタ＋記録時の取出し — 採用
- **Selected Approach**: 受信回数・受け渡し回数・消費時参照回数・無効値参照回数を MotionService が所有し、計測区間の開始・終了・取出しを提供する。消費側の参照記録は Session の読取り時に付随して呼び出す
- **Rationale**: 所有者を単一に保ち、Analyzer の純粋性を崩さない。記録内容は実測値のみとし、推定値を含めない
- **Trade-offs**: アプリ再起動をまたぐ比較はできないが、比較手順は同一起動内の区間計測で行うため不要
- **Follow-up**: 未計測項目の明記を含む記録形式を検証計画で定める

## Risks & Mitigations
- 低頻度化で重力の鮮度が落ち、傾き変化への追従が遅れる — 10Hz（0.1 秒周期）でも 3 秒確定則・0.5 秒保持に対して十分に細かいことを回帰で確認し、精度差を実測比較する
- 受け渡し省略の許容差が大きすぎると微小な傾き変化を落とす — 許容差を微小固定値とし、状態変化時は無条件で受け渡すことで緩和する
- 暗転時・背景移行の起停則への誤波及 — 起停メソッドの契約を変更せず、既存ライフサイクルテストを回帰に含める
- 実測なき効果記載 — 選定記録は実測値のみとし、未計測項目を明記する形式にする

## References
- `.kiro/specs/motion-frequency/brief.md` — 問題・方針・範囲の起点
- `.kiro/steering/roadmap.md` — 漸進的アプローチ、共有シーム、制約（推定値記載禁止等）
- `.kiro/specs/nekoze-fix/requirements.md` §4.1・§4.9・§7 — 天方向基準・代替鎖・デバイス向きの制約参照
- `CLAUDE.md` Architecture — 依存方向（Types → Domain → Services → Session → UI）と Session 唯一書込み点
