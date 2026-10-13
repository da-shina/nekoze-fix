# Requirements: motion-frequency

## Introduction
本機能は、姿勢監視中の重力更新の取得頻度と判定での利用頻度を計測した上で、垂直補正・端末回転・鏡像補正の整合性と代替基準への退行動作を保ちながら最適な更新頻度を選定する。計測先行で電力寄与を確認し、効果が小さい場合は変更を見送ることで、判定精度を損なわない省電力を実現する。

## Boundary Context (Optional)
- **In scope**: 重力更新頻度と判定での利用頻度の計測、カメラ処理頻度と重力更新の独立化、最新値優先と不要な連動更新の抑制、垂直補正・端末回転・鏡像補正の整合維持、現状・中間・低頻度の電力・精度比較、効果が小さい場合の見送り判断
- **Out of scope**: 映像の取得・推論処理の変更、猫背判定の閾値と代替基準の選択則の変更、暗転中の起動・停止方針の変更
- **Adjacent expectations**: 暗転時の省電力化は別機能が頻度調整の受口を利用することを想定し、本機能は受口の存在を前提とするが暗転時の切替方針自体は所有しない。重力由来の基準線表示と判定は天方向基準の選択則に従い、代替基準の表示・判定の継続は既存の扱いを維持する

## Requirements

### Requirement 1: 更新頻度と利用頻度の計測
**Objective:** As a 長時間利用するユーザー, I want 重力更新の取得頻度と判定での利用頻度が計測され記録されること, so that 頻度変更の効果判断を実測に基づいて行える

#### Acceptance Criteria
1. When 重力更新機能が動作している, the NekozeFix shall 単位時間あたりの重力更新回数と判定処理での利用回数を計測する
2. When 計測が行われる, the NekozeFix shall 映像フレーム処理の回数と重力更新の回数を独立した値として記録する
3. When 計測結果を記録する, the NekozeFix shall 計測条件としての監視状態・端末向き・計測期間を付して記録する

### Requirement 2: 更新頻度の比較選定と見送り判断
**Objective:** As a 長時間利用するユーザー, I want 現状・中間・低頻度の候補が電力と精度の実測で比較され最適な頻度が選ばれること, so that 精度を保ちながら無駄な取得を削減できる

#### Acceptance Criteria
1. When 現状頻度・中間頻度・低頻度の候補を比較する, the NekozeFix shall 各候補での電力消費の差を実測で比較できる
2. When 現状頻度・中間頻度・低頻度の候補を比較する, the NekozeFix shall 各候補での猫背判定の精度の差を実測で比較できる
3. If 低頻度化による電力改善が実測で確認できない, the NekozeFix shall 現状頻度を維持し頻度変更を追加しない
4. When 最適な更新頻度が選定される, the NekozeFix shall 選定根拠となった実測値を記録する

### Requirement 3: 処理頻度の独立化と最新値優先
**Objective:** As a 姿勢監視を利用するユーザー, I want 重力更新が映像処理の頻度に連動せず判定では常に最新の値が使われること, so that 頻度変更後も判定の鮮度が保たれる

#### Acceptance Criteria
1. While 映像フレーム処理の頻度が変化している, the NekozeFix shall 重力更新の頻度を連動させずに維持する
2. When 判定処理が重力値を必要とする, the NekozeFix shall その時点で最新の重力値を使用する
3. When 新しい重力値の到着時に判定で使用する値が変わらない, the NekozeFix shall 判定処理と表示更新を追加で発生させない
4. The NekozeFix shall 重力更新の受信回数に対して判定処理の実行回数を増やさない

### Requirement 4: 垂直補正・回転・鏡像の整合維持
**Objective:** As a 姿勢監視を利用するユーザー, I want 更新頻度にかかわらず天方向基準の表示と判定および端末回転・鏡像の扱いが保たれること, so that 向きを変えても正しく判定と表示が追従する

#### Acceptance Criteria
1. While 天方向基準で判定している, the NekozeFix shall 近側肩点を起点とする天方向基準線の表示と判定を一致させ続ける
2. When ユーザーが端末を回転させる, the NekozeFix shall 映像入力の向きと表示を自動的に新しい向きに追従させる
3. While 端末の回転が検出されている, the NekozeFix shall 猫背判定を一時停止する
4. When 端末の回転が完了する, the NekozeFix shall 猫背判定を再開する
5. Where 前面カメラで監視している, the NekozeFix shall 鏡像補正後の向きで基準線を表示し判定する
6. While いずれの更新頻度で動作している, the NekozeFix shall 猫背確定に3秒間の連続検知を要する意味を変えない

### Requirement 5: 代替基準への退行と復帰
**Objective:** As a 姿勢監視を利用するユーザー, I want 重力計測が使えない場合でも代替基準で判定と表示が継続し復帰時に天方向基準へ戻ること, so that 監視が中断されない

#### Acceptance Criteria
1. If 端末の重力計測が利用できない, the NekozeFix shall 両肩ライン直交上向き法線を代替基準として判定と表示を継続する
2. If 端末の重力計測が利用できず両肩ライン直交も算出できない, the NekozeFix shall 画像上向き垂直を最終代替基準として判定と表示を継続する
3. While 代替基準で動作している, the NekozeFix shall 天方向の計測が復帰し次第天方向基準に復帰する
4. While 代替基準で動作している, the NekozeFix shall 判定と同じ代替基準の基準線を通常と同じ見た目で表示する
5. When 一時的な無効値が発生する, the NekozeFix shall 直前の有効値を定められた保持期間に限り使用する
6. When 更新頻度を変更する, the NekozeFix shall 無効時の直前有効値の保持期間の意味を変えない

### Requirement 6: 起動・停止とライフサイクルの維持
**Objective:** As a 姿勢監視を利用するユーザー, I want 監視・校正・暗転・背景移行での重力更新の起動停止の扱いが保たれること, so that 既存の利用手順と省電力の両立が崩れない

#### Acceptance Criteria
1. When 監視または校正を開始する, the NekozeFix shall 重力更新を開始する
2. When 監視を停止する, the NekozeFix shall 重力更新を停止し保持値を破棄する
3. While 画面暗転モード中である, the NekozeFix shall 重力更新を継続する
4. When アプリが背景に移行する, the NekozeFix shall 重力更新を停止する
5. Where 暗転時の省電力化が重力更新頻度の変更を必要とする, the NekozeFix shall 頻度変更を受け付ける手段を提供する

### Requirement 7: 適用範囲の限定と計測規律
**Objective:** As a 品質を維持したい関係者, I want 本機能の変更が判定仕様に及ばず実測に基づく記録のみが行われること, so that 効果未確認の変更や推定値の混入を防げる

#### Acceptance Criteria
1. When 本機能の変更を適用する, the NekozeFix shall 映像の取得処理と推論処理の動作を変えない
2. When 本機能の変更を適用する, the NekozeFix shall 猫背判定の閾値と代替基準の選択則を変更しない
3. When 選定結果と計測結果を記録する, the NekozeFix shall 実測していない省電力率や持続時間を記載せず未計測項目を明記する
4. If 比較に必要な実測が揃わない, the NekozeFix shall 頻度変更を追加せず現状頻度を維持する
