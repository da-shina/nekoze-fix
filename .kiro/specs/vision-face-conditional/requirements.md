# Requirements: vision-face-conditional

## Introduction

長時間の姿勢監視中に不要な顔推論によるバッテリー消費を削減するため、人体姿勢が有効に検出できたフレームでは顔検出を省略し、キーポイント不足時のみ顔検出で人物の有無を判定する条件付き実行を導入する。人物検出の意味（人物あり・姿勢不明・人物不在の区別）と猫背判定の振る舞いは変更せず、既存の警告表示・信頼度閾値・近側選択・状態遷移を維持したまま推論回数を削減する。

## Boundary Context

- **In scope**: 姿勢有効時の顔検出省略、キーポイント不足時の顔検出による人物有無判定、人物検出意味の維持（人物あり・姿勢不明・人物不在）、既存の警告・閾値・選択則の維持、成功経路と失敗経路それぞれの推論回数・推論時間の計測
- **Out of scope**: 推論頻度の制限・間引き、検出実行スレッド構造の変更、顔検出の完全削除、判定ロジック自体の変更（角度・距離閾値、3秒確定の意味変更）、画面表示・スナップショット更新・通知音・画面暗転・動作検知の変更
- **Adjacent expectations**: 本機能はnekoze-fix仕様の§3人物検出と§4判定（信頼度閾値・近側選択・中央人物選択）を制約として参照し、その振る舞いを変更しない。本機能はvision-fps-throttleの前提となり、成功率・失敗率の計測値を下流の間引き設計に引き渡す。人物不在時の警告表示と校正・監視の状態遷移は既存仕様に従い継続する。

## Requirements

### Requirement 1: 姿勢有効時の顔検出省略

**Objective:** As a 長時間監視する利用者, I want 姿勢が有効に検出できたフレームで顔検出が省略されること, so that 不要な推論によるバッテリー消費が削減される

#### Acceptance Criteria

1. When 人体姿勢の検出が有効なキーポイントを返した, the NekozeFix shall 顔検出を実行せずに姿勢検出結果を確定する
2. While 人体姿勢の検出が連続して有効である, the NekozeFix shall 顔検出の実行を省略し続ける
3. When 顔検出を省略した, the NekozeFix shall 姿勢角度・キーポイント内容・人物位置の選択結果を省略前と同一に保つ
4. When 姿勢観測はあるが4点全てがnilのPoseFrameである, the NekozeFix shall 成功経路とみなして顔検出を省略し、.pose経路（ホールド継続）で処理して.personOnly経路の肩欠測デバウンスとは別扱いにすること

### Requirement 2: キーポイント不足時の顔検出フォールバック

**Objective:** As a 監視中の利用者, I want 姿勢キーポイントが不足する場合でも顔検出で人物の有無が判定されること, so that 接写での俯きなど姿勢が取れない状況でも人物不在と誤判定されない

#### Acceptance Criteria

1. When 人体姿勢の検出が有効なキーポイントを返さなかった, the NekozeFix shall 顔検出を実行して人物の有無を判定する
2. When 顔が検出されたが有効な姿勢キーポイントがない, the NekozeFix shall 人物あり・姿勢不明として扱い猫背判定を行わない
3. If 顔も姿勢も検出されない, the NekozeFix shall 人物不在として扱う
4. Where 複数の顔または複数の人物が検出される, the NekozeFix shall 画面中央に最も近い人物のみを判定に使用する

### Requirement 3: 人物検出意味と判定前提の維持

**Objective:** As a 監視中の利用者, I want 条件付き実行の前後で人物検出の意味と判定前提が変わらないこと, so that 警告表示と猫背判定の信頼性が維持される

#### Acceptance Criteria

1. If カメラに人物が検出されない, the NekozeFix shall 人物が検出できない旨を表示する
2. Where キーポイントの信頼度が向き別の閾値（ポートレート0.3／ランドスケープ0.1）未満である, the NekozeFix shall 該当キーポイントを猫背判定から除外する
3. Where 片方の肩または耳のキーポイントのみが検出される, the NekozeFix shall 検出された側のみを使用して猫背判定を継続する
4. When 両側の耳ー肩ペアが判定に使用できる, the NekozeFix shall 解決済み基準線との鋭角がより大きいペアを近側として選択し、両側の角度差が5度未満の場合は前回の近側を維持する
5. When 顔のみで人物ありが判定された, the NekozeFix shall 肩欠測として扱い猫背判定を行わず警告のちらつきを抑えるための猶予則を維持する

### Requirement 4: 校正・監視の状態遷移維持

**Objective:** As a 監視中の利用者, I want 校正と監視の状態遷移が条件付き実行の前後で変わらないこと, so that 既存の操作手順と復帰挙動が維持される

#### Acceptance Criteria

1. If カメラに人物が検出されない, the NekozeFix shall キャリブレーションの完了を許可せず、人物をフレーム内に収めるよう促す
2. While 猫背状態が3秒間連続して検知されている, the NekozeFix shall 確定猫背判定とし、3秒未満で解除された場合は猫背判定を行わない
3. When 姿勢が有効なすべての指標で閾値未満に戻る, the NekozeFix shall 即座に改善と判定する
4. While 代替基準で動作している, the NekozeFix shall 天方向の計測が復帰し次第、天方向基準に復帰する
5. When 人物不在・姿勢不明・肩欠測が発生する, the NekozeFix shall 既存の猶予・ホールド・平滑化の振る舞いを変えずに表示と蓄積を継続する

### Requirement 5: 推論回数と推論時間の計測

**Objective:** As a 効果を検証する開発者, I want 成功経路と失敗経路の推論回数と推論時間が区別して把握できること, so that 削減効果を実測で裏付けられる

#### Acceptance Criteria

1. While 姿勢有効により顔検出を省略している, the NekozeFix shall 省略した顔検出の回数を成功経路の削減分として数えられること
2. While キーポイント不足により顔検出を実行している, the NekozeFix shall 顔検出を実行した回数を失敗経路の実行分として数えられること
3. The NekozeFix shall 成功経路と失敗経路それぞれの推論時間の実測値を記録すること
4. The NekozeFix shall 実測していない省電力率や持続時間を効果として記載しない

### Requirement 6: 判定算出と監視体験の非回帰

**Objective:** As a 監視中の利用者, I want 最適化の前後で判定算出と監視体験が変わらないこと, so that 精度劣化や操作変更なしに省電力を享受できる

#### Acceptance Criteria

1. The NekozeFix shall 耳ー肩角度・垂直ベクトル・回転／鏡像／画面比率補正の算出結果を条件付き実行の前後で変えない
2. The NekozeFix shall カメラ映像の取得頻度と監視開始／停止・画面暗転・通知音・動作検知の振る舞いを変えない
3. If 顔検出に人物検出フォールバック以外の用途が確認される, the NekozeFix shall 当該用途を残すため顔検出の無条件削除を行わない
