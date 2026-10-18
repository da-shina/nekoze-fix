# Requirements: absent-vision-reduction

## Introduction

長時間人物不在が続いた場合の視覚処理削減。dim-mode-saving 4.2 の実測(`absent-vision-cost-4-2.md`)で、人物不在時は姿勢観測が0件となるため顔フォールバック(ADR-0021)が毎推論で実行され、推論あたりの視覚処理時間が約2倍(約17ms→約34ms)、時間窓あたりの視覚処理量が人物在席時より増えることが判明した。本機能は、長時間不在中に顔フォールバックの実行頻度を間引くことにより視覚処理量を削減し、電力消費を抑える。顔のみ検出を「人物あり」とする既存の検出意味は維持し、判定・通知・監視継続を変えない。

## Boundary Context

- **In scope**: 通常モード・画面暗転モードを問わない長時間不在の検出と解除、長時間不在中の顔フォールバック実行頻度の削減、顔のみ検出の人物検出意味の維持、長時間不在解除時の通常実行への復帰、視覚処理量・電力の実測記録、判定・通知・監視継続の回帰検証
- **Out of scope**: 判定ロジック(3秒連続確定判定・判定閾値・近側キーポイント選択・代替基準鎖)の変更、通知仕様の変更、UI デザインの変更、バックグラウンド監視、カメラ取得の停止、推論実行頻度の上限自体の変更、新規依存の追加
- **Adjacent expectations**: vision-face-conditional(ADR-0021)が定める顔フォールバックと人物検出3値(姿勢あり・人物あり姿勢不明・人物不在)の意味を前提とし、本機能はその意味を変えない。dim-mode-saving が定める不在しきい値・省電力段階を共用し、本機能は段階遷移則自体を変更しない。mainactor-throttle・motion-frequency の既存則は変更しない。
- **用語の扱い**: 「長時間不在」を画面暗転モードに限らず通常モードにも一般化するため、CONTEXT.md の該当定義(および不在しきい値の説明)の更新を design フェーズで行う。

## Requirements

### Requirement 1: 長時間不在の検出と解除(通常・暗転共通)
**Objective:** As a 長時間監視する利用者, I want 人物が不在のまま長く続いたことをモードを問わず検出してほしい, so that 通常モードでも省電力の恩恵を受けられる

#### Acceptance Criteria
1. While 監視中, the NekozeFix shall 人物が検出されない状態の継続時間を計測する
2. When 人物不在が不在しきい値を超えて継続する, the NekozeFix shall 通常モードおよび画面暗転モードのいずれでも、その状態を長時間不在として扱う
3. When 長時間不在中に人物が検出される, the NekozeFix shall 長時間不在を解除する
4. The NekozeFix shall 不在しきい値に dim-mode-saving と同一の値を共用し、暗転段階の遷移とは独立に長時間不在を判定する

### Requirement 2: 長時間不在中の顔フォールバック実行削減
**Objective:** As a 長時間監視する利用者, I want 長時間不在中は顔フォールバックの実行が間引かれること, so that バッテリー消費が抑えられる

#### Acceptance Criteria
1. While 長時間不在中, the NekozeFix shall 姿勢観測ゼロ件時に実行する顔検出(顔フォールバック)の実行頻度を、人物在席時の通常実行より低くする
2. While 画面暗転モードの長時間不在中, the NekozeFix shall 一定時間窓あたりの視覚処理量を、画面暗転段階より低くする
3. While 長時間不在中, the NekozeFix shall カメラフレームの取得を継続し、推論実行頻度の上限を通常モードおよび画面暗転段階から変更しない
4. When 長時間不在が解除される, the NekozeFix shall 顔フォールバックの実行頻度を通常水準へ戻す

### Requirement 3: 顔フォールバック削減下での人物検出意味の維持
**Objective:** As a 利用者, I want 顔のみでも人物を検出する意味が保たれること, so that 俯いた姿勢でも監視が途切れない

#### Acceptance Criteria
1. While 長時間不在中, the NekozeFix shall 顔検出を実行した推論では、顔のみ検出を「人物あり」として扱う既存の意味を維持する
2. When 長時間不在中に顔のみ検出の人物が現れる, the NekozeFix shall 顔フォールバックの実行間隔の範囲内でその人物を検出し、恒久的に人物なし扱いとしない
3. While 長時間不在でない場合, the NekozeFix shall 顔フォールバックの実行頻度と人物検出の意味を変更しない
4. The NekozeFix shall 通常モードおよび画面暗転モードで、人物なしの判定基準と表示則(暗転中の抑制・復帰時の表示)を変更しない

### Requirement 4: 判定・通知・監視継続の不変
**Objective:** As a 利用者, I want 視覚処理を削減しても判定と監視が変わらないこと, so that 省電力と引き換えに検知品質を失わない

#### Acceptance Criteria
1. While 顔フォールバックを削減している, the NekozeFix shall 3秒連続確定判定と判定閾値の意味を変更しない
2. While 顔フォールバックを削減している, the NekozeFix shall 近側キーポイント選択と代替基準鎖の選択則を変更しない
3. While 顔フォールバックを削減している, the NekozeFix shall 通知仕様(通知音・再通知間隔)を変更しない
4. While 長時間不在中, the NekozeFix shall カメラ取得を停止せず監視を継続する
5. When 長時間不在が解除される, the NekozeFix shall 検出・判定・通知の通常経路を再開する

### Requirement 5: 条件別の実測記録
**Objective:** As a 効果を検証する開発者, I want 長時間不在の視覚処理削減が実測で確認されること, so that 省電力効果を推定ではなく実測で判断できる

#### Acceptance Criteria
1. When 視覚処理削減の効果を確認する, the NekozeFix shall 通常モードの長時間不在・画面暗転モードの長時間不在のそれぞれで、視覚処理量と電力指標を、画面暗転段階および人物在席時と同一端末・同一セッションで比較した実測値として記録する
2. The NekozeFix shall 実測していない省電力率・持続時間の推定値、および実測指標からの換算・外挿による推計値を記録に含めない
3. Where 測定できない項目がある場合, the NekozeFix shall 当該項目を未計測として明記する
4. When 電力指標を記録する場合, the NekozeFix shall dim-mode-saving(ADR-0025)と同一の実機計測手段(Average Energy Impact ゲージ評価・Average Component Utilization の領域別%)を用いる