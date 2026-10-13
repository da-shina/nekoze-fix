# Requirements: dim-mode-saving

## Introduction
本機能は、画面暗転モードを省電力モードの切替点として扱い、監視継続を原則としながら不要処理を段階的に削減する。通常・暗転・長時間人物不在の各段階で推論実行頻度とセンサー稼働を見直し、通常モードより低いバッテリー消費を実測で確認できる状態にする。輝度制御・自動スリープ抑止・センサー稼働を独立に制御し、利用者が期待する監視動作を説明なく変更しない。

## Boundary Context (Optional)
- **In scope**: 暗転中の必要処理と不要処理の区分、暗転時の推論実行頻度の低下、長時間人物不在時の更なる低下方式、カメラ停止の影響評価（採用は評価完了後のみ）、画面点灯抑止とカメラ・センサー稼働の分離制御、暗転移行・復帰の回帰確認、各条件での電力・復帰時間・精度の実測記録
- **Out of scope**: 通常モードの推論実行頻度・センサー取得頻度の決定自体（上流specの選定結果を利用するのみ）、猫背判定ロジック・通知仕様の変更、暗転UIデザインの変更、バックグラウンド監視の追加、カメラ権限・ライフサイクル仕様の変更
- **Adjacent expectations**: 推論実行頻度の低下方式は vision-fps-throttle の確定方式に依存し、低下幅の決定自体は本機能では行わない。センサー取得頻度の低下方式は motion-frequency の確定方式に依存し、頻度候補の選定自体は本機能では行わない。自動スリープ抑止の基本則（監視中に限定、暗転解除操作と無関係）は nekoze-fix 仕様 §8.3／§8.4 に従い、本機能はその則を変更しない

## Requirements

### Requirement 1: 暗転中の監視継続
**Objective:** As a 長時間監視を行う利用者, I want 画面暗転モード中も姿勢検知と通知が継続すること, so that 画面を暗くして省電力しながら監視を続けられる

#### Acceptance Criteria
1. While 画面暗転モード中, the NekozeFix shall カメラプレビューを非表示にし、姿勢検知と通知機能を継続する
2. When ユーザーが画面暗転操作を行う, the NekozeFix shall 画面輝度を下げて画面暗転モードに移行する
3. When ユーザーが画面をタップする, the NekozeFix shall 画面暗転モードを解除し、通常表示に戻る

### Requirement 2: 暗転時の段階的な推論頻度低下
**Objective:** As a 長時間監視を行う利用者, I want 暗転中は推論実行頻度が通常より低下すること, so that 監視を続けながらバッテリー消費を抑えられる

#### Acceptance Criteria
1. When 画面暗転モードに移行する, the NekozeFix shall 推論実行頻度を通常モードより低下させる
2. While 画面暗転モードが継続し、かつ人物が長時間検出されない, the NekozeFix shall 推論実行頻度を暗転直後よりさらに低下させる
3. When 画面暗転モードを解除する, the NekozeFix shall 推論実行頻度を通常モードの水準に戻す
4. While 推論実行頻度を低下させている, the NekozeFix shall 3秒連続確定判定の意味を変更しない

### Requirement 3: 暗転時のセンサー稼働見直し
**Objective:** As a 長時間監視を行う利用者, I want 暗転中はセンサー取得頻度が通常より低下すること, so that 判定に必要な取得を保ちながら不要な取得を削減できる

#### Acceptance Criteria
1. When 画面暗転モードに移行する, the NekozeFix shall 重力取得頻度を通常モードより低下させる
2. While 画面暗転モード中, the NekozeFix shall 重力取得自体は継続し、代替基準への退行則を変更しない
3. When 画面暗転モードを解除する, the NekozeFix shall 重力取得頻度を通常モードの水準に戻す

### Requirement 4: 表示・センサー・スリープ抑止の独立制御
**Objective:** As a 長時間監視を行う利用者, I want 画面の暗さ・センサー稼働・スリープ抑止が互いに影響せず制御されること, so that 暗転操作や復帰操作で監視状態が意図せず変わらない

#### Acceptance Criteria
1. While 監視中であり、かつ画面暗転モードである, the NekozeFix shall 自動スリープ抑止を継続し、暗転モードの解除操作と無関係に維持する
2. When 監視が停止する、またはアプリがフォアグラウンドから退避する, the NekozeFix shall 自動スリープ抑止をオペレーティングシステムの標準設定に戻す
3. When 画面暗転モードを解除する, the NekozeFix shall 暗転前の画面輝度を復元し、センサー稼働状態を変更しない
4. Where 監視中でない（権限待ち・校正中・待機中）場合, the NekozeFix shall 自動スリープ抑止を行わず標準設定のままとする

### Requirement 5: カメラ停止の採用条件
**Objective:** As a 監視継続を期待する利用者, I want カメラ停止が影響評価なしに導入されないこと, so that 暗転中に検知が止まる事態を避けられる

#### Acceptance Criteria
1. If 暗転中のカメラ停止に関する監視継続・復帰時間・検出精度への影響評価が完了していない, the NekozeFix shall カメラ取得を停止しない
2. Where 暗転中のカメラ停止を採用する場合, the NekozeFix shall 事前の影響評価記録に基づき、監視継続への影響を利用者に説明できる状態にする
3. While カメラ停止を採用した暗転モード中, the NekozeFix shall 復帰操作時に通常モードの監視状態へ復帰できる

### Requirement 6: 復帰性能と判定・通知の維持
**Objective:** As a 長時間監視を行う利用者, I want 暗転復帰後も判定と通知が通常通り動作すること, so that 省電力のために検知の確実性を失わない

#### Acceptance Criteria
1. When 画面暗転モードを解除する, the NekozeFix shall 通常モードの監視状態に復帰し、姿勢検知と通知機能が継続する
2. While 画面暗転モード中および復帰直後, the NekozeFix shall 猫背判定の閾値・確定則・代替基準の選択則を変更しない
3. When 暗転中または復帰直後に猫背が確定判定される, the NekozeFix shall 通知仕様（通知音・再通知間隔）を通常モードと同一に維持する

### Requirement 7: 条件別の実測記録
**Objective:** As a 効果を検証する開発者, I want 通常・暗転・不在・復帰・長時間の各条件で電力・復帰時間・精度が実測記録されること, so that 省電力効果を推定ではなく実測で判断できる

#### Acceptance Criteria
1. When 省電力効果を記録する, the NekozeFix shall 通常モード・暗転モード・長時間人物不在・復帰直後・長時間監視の各条件で電力消費・復帰時間・検出精度を実測値として記録する
2. The NekozeFix shall 実測していない省電力率・持続時間の推定値を記録に含めない
3. Where 測定できない項目がある場合, the NekozeFix shall 当該項目を未計測として明記する

### Requirement 8: 暗転時の消費電力低減
**Objective:** As a 長時間監視を行う利用者, I want 画面暗転モード中の消費電力が通常モードより低いこと, so that 長時間利用時の電池持ちが改善される

#### Acceptance Criteria
1. While 画面暗転モード中, the NekozeFix shall 通常モードよりもバッテリー消費を低減する
2. When 暗転時と通常時の消費電力を比較する, the NekozeFix shall 実測値に基づき低減を確認し、推定値による判定を行わない
