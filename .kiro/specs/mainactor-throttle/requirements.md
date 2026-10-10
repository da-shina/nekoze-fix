# Requirements: mainactor-throttle

## Introduction

長時間の姿勢監視中にカメラのフレーム到達ごとにMainへの受け渡しが発生し、表示更新に不要な中間結果までMainでの反映処理が消費され、バッテリーとCPUを消費している。姿勢判定の継続性を維持しながら表示更新のみを独立最適化し、不要な中間結果の破棄・最新結果優先・不変値の書込み回避によりMainへの受け渡し頻度を削減する。推論FPS確定後の受け渡し頻度を最適化する最終段として、処理順序「間引き→条件化→受け渡し削減」を保ち、受け渡し削減が判定の継続性に波及しない分離を実現する。受け渡し前段の待ち時間・蓄積状況の計測を含み、通知遅延と復帰時間の回帰を確認する。

## Boundary Context

- **In scope**: Main受け渡し前段の待ち時間・蓄積状況の計測、表示に不要な中間結果の破棄・最新結果優先による受け渡し頻度削減、スナップショット書込みのまとめ化と不変値の書込み回避、判定処理と表示処理の分離、状態表示・通知タイミングの維持、書込み経路の単一性とデータ競合の回避、計測シナリオでの記録
- **Out of scope**: 推論FPS自体の制限、顔条件化の判定内容、判定閾値・3秒確定ロジックの変更、判定算出自体の変更、UIデザイン変更、Motion受信の受け渡し・暗転表示切替の変更
- **Adjacent expectations**: 本機能はvision-fps-throttleの推論FPS確定値とvision-face-conditionalの検出結果の3値の意味を上流前提として利用し、処理順序「間引き→条件化→受け渡し削減」の最終段に位置する。本機能はnekoze-fix仕様の§3.3（状態表示）・§5（通知フィードバック）・NFR 8.2（確定→再生0.5秒以内）・§8（ライフサイクル）を制約として参照し、その振る舞いを変更しない。本機能はdim-mode-savingとスナップショット書込みを共有するため、暗転中の監視継続と復帰の振る舞いを変更しない。

## Requirements

### Requirement 1: Main受け渡し前段の待ち時間・蓄積状況の計測

**Objective:** As a 効果を検証する開発者, I want 検出結果がMainでの反映を待つ間の待ち時間と蓄積状況が把握できること, so that 受け渡し削減の対象と効果を実測で裏付けられる

#### Acceptance Criteria

1. While 姿勢監視中である, the NekozeFix shall 検出結果がMainでの反映を待つ待ち時間を計測すること
2. While 姿勢監視中である, the NekozeFix shall Mainへの受け渡し待ちに蓄積した検出結果の数を数えられること
3. The NekozeFix shall 待ち時間と蓄積状況の計測値を検証時に読み出せること

### Requirement 2: 不要中間結果の破棄と最新結果優先による受け渡し頻度削減

**Objective:** As a 長時間監視する利用者, I want 表示に不要な中間結果が破棄され最新の結果が優先して渡されること, so that フレーム到達に比例したMainでの反映処理によるバッテリー消費が削減される

#### Acceptance Criteria

1. When 新しい検出結果がMainへの受け渡し待ちに加わった, the NekozeFix shall 表示に不要な中間結果を破棄し最新の結果を優先して渡すこと
2. Where 検出結果の到達頻度が表示更新に必要な頻度を上回る, the NekozeFix shall Mainへの受け渡し頻度を到達頻度より抑えること
3. When 受け渡し待ちの最新結果がある, the NekozeFix shall 古い中間結果の遅延反映による表示の古びや停止を起こさないこと

### Requirement 3: スナップショット書込みのまとめ化と不変値の書込み回避

**Objective:** As a 長時間監視する利用者, I want 表示更新に必要な項目がまとめて反映され変わっていない不変値の書込みが省略されること, so that Mainでの不要な書込みと再描画による消費が削減される

#### Acceptance Criteria

1. While 姿勢監視中である, the NekozeFix shall 表示更新に必要な項目をまとめて反映し中間的なちらつきを起こさないこと
2. When 前回表示時から値が変わっていない不変の表示項目がある, the NekozeFix shall 当該項目の書込みを省略すること
3. When 画面比率などの不変値が変化した, the NekozeFix shall 当該項目の表示を変化後の値で更新すること

### Requirement 4: 判定継続性の維持と判定系の非回帰

**Objective:** As a 監視中の利用者, I want 表示更新の削減前後で姿勢判定の継続性と判定算出が変わらないこと, so that 検知精度の劣化なしに省電力を享受できる

#### Acceptance Criteria

1. When 表示更新のための受け渡しが抑えられる, the NekozeFix shall 姿勢判定の継続に用いる検出結果の流れを欠落させないこと
2. While 猫背状態が3秒間連続して検知されている, the NekozeFix shall 確定猫背判定とし、3秒未満で解除された場合は猫背判定を行わないこと
3. The NekozeFix shall 耳ー肩角度・垂直ベクトル・回転／鏡像／画面比率補正の算出結果を削減の前後で変えないこと
4. When 人物不在・姿勢不明・肩欠測が発生する, the NekozeFix shall 既存の猶予・ホールド・平滑化の振る舞いを変えずに表示と蓄積を継続すること
5. The NekozeFix shall 推論実行の要否・頻度の判断と顔条件化の検出結果の意味を変えないこと

### Requirement 5: 状態表示・通知タイミング・復帰の非回帰

**Objective:** As a 監視中の利用者, I want 削減の前後で状態表示と通知タイミングと復帰の振る舞いが変わらないこと, so that 既存の監視体験と即時フィードバックが維持される

#### Acceptance Criteria

1. While 姿勢監視中である, the NekozeFix shall 現在の姿勢が良好または猫背のいずれかを表示すること
2. When 猫背が確定判定される, the NekozeFix shall 通知音を0.5秒以内に再生すること
3. When 姿勢が改善判定される, the NekozeFix shall 通知音の再生を停止し再通知タイマーをリセットすること
4. The NekozeFix shall 画面暗転中の監視継続と復帰および監視開始／停止・背景移行・復帰の振る舞いを変えないこと

### Requirement 6: 書込み経路の単一性とデータ競合の回避

**Objective:** As a 効果を検証する開発者, I want セッション状態の書込み経路が単一に保たれデータ競合が起きないこと, so that 受け渡し削減後も状態の一貫性と動作の安定性が維持される

#### Acceptance Criteria

1. The NekozeFix shall セッション状態の書込みを単一の書込み経路に保つこと
2. If 複数の検出結果が短時間に到達する, the NekozeFix shall 状態の不整合やデータ競合を起こさず最新の結果で一貫性を保つこと
3. The NekozeFix shall Motion受信の受け渡しと暗転表示切替の振る舞いを変えないこと

### Requirement 7: 計測シナリオでの記録と推定記載禁止

**Objective:** As a 効果を検証する開発者, I want 代表的シナリオでの実測値が記録されること, so that 省電力効果と回帰有無の判断が実測に基づくものになる

#### Acceptance Criteria

1. The NekozeFix shall 通常・暗転・不在・復帰・猫背・長時間の計測シナリオにおけるMain受け渡し頻度・待ち時間・CPU使用率・通知遅延・復帰時間を記録すること
2. The NekozeFix shall 実測していない省電力率や持続時間を効果として記載しないこと
3. If 計測できていない項目がある, the NekozeFix shall 当該項目を未計測として明記すること
