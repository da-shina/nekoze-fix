# Requirements: vision-fps-throttle

## Introduction

長時間の姿勢監視中にカメラのネイティブレートで到達する全フレームがVision推論に消費され、判定に不要な高頻度推論がバッテリーを消費している。カメラ入力FPSとVision実行FPSを独立に制御・計測し、現状実測値・15FPS・10FPSを比較した上で3秒確定判定の意味を変えずに推論FPSを制限し、推論待ちの蓄積なく最新フレーム優先で動作する間引きを導入する。共有呼出点での処理順序は「間引き→条件化」とし、カメラセッション停止・再開時のFPS制御状態の初期化を含む。

## Boundary Context

- **In scope**: 入力FPS・推論FPSの個別計測、推論対象外フレームの早期破棄、時刻基準の選定、重複実行の防止、無制限蓄積の回避（最新フレーム優先）、遅延フレーム破棄の振る舞い維持、停止・再開時の状態初期化、既存設計に合ったFPS設定方法の選定、計測シナリオでの記録
- **Out of scope**: 顔条件化ロジック自体、検出実行スレッド構造の変更、3秒確定・角度／補正ロジックの変更、カメラ解像度・プリセットの変更、スナップショット書込み頻度・UI更新の間引き、動作検知・画面暗転モードの変更
- **Adjacent expectations**: 本機能はvision-face-conditionalの条件付き実行の上流に位置し、間引きを通過したフレームのみを条件化の判定対象として渡す。本機能はnekoze-fix仕様の§4.2（3秒確定）・NFR 8.1（15fps以上構造）・0.5秒系ホールドと平滑化定数を制約として参照し、その振る舞いを変更しない。本機能はmainactor-throttleとdim-mode-savingの下流前提となり、入力FPS・推論FPSの計測値を引き渡す。

## Requirements

### Requirement 1: 入力FPSと推論FPSの独立計測

**Objective:** As a 効果を検証する開発者, I want カメラ入力FPSとVision実行FPSが区別して把握できること, so that 間引き効果とNFR整合を実測で裏付けられる

#### Acceptance Criteria

1. While 姿勢監視中である, the NekozeFix shall カメラから到達したフレームに基づく入力FPSを計測すること
2. While 姿勢監視中である, the NekozeFix shall Vision推論を実行した回数に基づく推論FPSを入力FPSと区別して計測すること
3. The NekozeFix shall 入力FPSと推論FPSの計測値を検証時に読み出せること

### Requirement 2: 時刻基準の推論対象外フレーム早期破棄

**Objective:** As a 長時間監視する利用者, I want 推論対象外フレームが推論実行前に破棄されること, so that 判定に不要な高頻度推論によるバッテリー消費が削減される

#### Acceptance Criteria

1. When カメラが新しいフレームを配信した, the NekozeFix shall 時刻基準の間引き判定により推論対象外フレームを推論実行前に破棄すること
2. When 間引き判定を行う, the NekozeFix shall フレーム到着順序ではなく時刻間隔を基準に推論対象を選定すること
3. Where 推論FPSの上限が設定されている, the NekozeFix shall 上限を超える頻度でVision推論を実行しないこと
4. When フレームが間引きを通過した, the NekozeFix shall 当該フレームのみを顔条件付き実行の判定対象として渡すこと

### Requirement 3: 最新フレーム優先と実行の健全性

**Objective:** As a 監視中の利用者, I want 推論待ちの蓄積なく最新フレーム優先で動作すること, so that 古いフレームの遅延処理による判定の古びや停止が発生しない

#### Acceptance Criteria

1. While Vision推論の実行中である, the NekozeFix shall 推論待ちフレームを無制限に蓄積せず最新フレームを優先して扱うこと
2. The NekozeFix shall 同一フレームに対するVision推論の重複実行を行わないこと
3. While 推論処理が遅延している, the NekozeFix shall 遅延フレームを破棄する既存の振る舞いを維持すること

### Requirement 4: 3秒確定判定と判定系の非回帰

**Objective:** As a 監視中の利用者, I want 間引きの前後で3秒確定判定と判定算出が変わらないこと, so that 検知精度の劣化なしに省電力を享受できる

#### Acceptance Criteria

1. While 猫背状態が3秒間連続して検知されている, the NekozeFix shall 確定猫背判定とし、3秒未満で解除された場合は猫背判定を行わないこと
2. The NekozeFix shall 耳ー肩角度・垂直ベクトル・回転／鏡像／画面比率補正の算出結果を間引きの前後で変えないこと
3. When 人物不在・姿勢不明・肩欠測が発生する, the NekozeFix shall 既存の猶予・ホールド・平滑化の振る舞いを変えずに表示と蓄積を継続すること
4. The NekozeFix shall カメラ解像度・プリセットを変更しないこと

### Requirement 5: FPS設定方法の選定と比較

**Objective:** As a 効果を検証する開発者, I want 推論FPSの制限値が実測比較に基づいて選定されること, so that 根拠のない固定値による過度な間引きや効果不足を避けられる

#### Acceptance Criteria

1. When 推論FPSの上限を定める, the NekozeFix shall 現状実測値・15FPS・10FPSの比較に基づいて既存設計に合った設定方法を選ぶこと
2. The NekozeFix shall 推論FPSの上限値を根拠なく固定しないこと
3. When NFR 8.1との整合を確認する, the NekozeFix shall 入力FPSと推論FPSの独立計測に基づいて検証し推定で記載しないこと

### Requirement 6: 停止・再開時の状態初期化と実行場所の維持

**Objective:** As a 監視中の利用者, I want カメラ停止・再開の前後でFPS制御が正しく継続すること, so that 再開直後の過剰な破棄や古い状態による判定の乱れが発生しない

#### Acceptance Criteria

1. When カメラセッションが停止または再開する, the NekozeFix shall FPS制御の状態を初期化すること
2. The NekozeFix shall 検出処理の実行場所と結果受け渡しの振る舞いを変えないこと
3. The NekozeFix shall 監視開始／停止・画面暗転・通知音・動作検知の振る舞いを変えないこと
4. The NekozeFix shall スナップショット書込み頻度・UI更新の間引きを行わないこと

### Requirement 7: 計測シナリオでの記録と推定記載禁止

**Objective:** As a 効果を検証する開発者, I want 代表的シナリオでの実測値が記録されること, so that 省電力効果の判断が実測に基づくものになる

#### Acceptance Criteria

1. The NekozeFix shall 通常・暗転・不在・復帰・猫背・長時間の計測シナリオにおける入力FPS・推論FPS・推論時間・待ち時間・CPU使用率を記録すること
2. The NekozeFix shall 実測していない省電力率や持続時間を効果として記載しないこと
3. If 計測できていない項目がある, the NekozeFix shall 当該項目を未計測として明記すること
