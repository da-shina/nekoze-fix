# Implementation Plan

- [x] 1. 配送判定契約の骨格とテスト基盤を確立する
  - 配送可否の型と申請・初期化・計数読出しの骨格を新規ゲートファイルに定義する
  - 空の単体テストファイルを追加し、テストターゲットがコンパイル通過することを確認する
  - 骨格のテスト実行によりテスト基盤が動作することを確認する
  - _Boundary: NekozeFix/Session/MainHopGate.swift（新規・骨格のみ）、NekozeFixTests/MainHopGateTests.swift（基盤のみ。PostureSessionManager呼出点には触れない）_
  - _Requirements: 1.3, 2.1_

- [x] 2. 受け渡し集約器と計測器を実装する
- [x] 2.1 定常間引き・遷移強制・校正中全量の配送判定と最新優先保持を実装する
  - 検出種別遷移と非 pose 結果を間隔にかかわらず配送対象とする
  - 校正フェーズ中の申請を全量配送とする
  - 定常 pose 連続のみ表示更新間隔で間引きし、不通過分は単一スロットに最新のみ保持する
  - 判定条件の境界と最新優先が単体テストで検証できることを確認する
  - _Boundary: NekozeFix/Session/MainHopGate.swift（受け渡し集約器のみ。PostureSessionManager呼出点・PoseDetector・表示書込みには触れない）_
  - _Requirements: 2.1, 2.2, 2.3, 4.1, 6.2_
- [x] 2.2 申請数・配送数・破棄数・待ち時間の計数と複写読出しと初期化を実装する
  - 判定点での計数が取りこぼしなく進むことを確認する
  - 読出しが複写であり計測の有無で配送挙動が変わらないことを確認する
  - 初期化直後の判定が初期状態に戻ることを確認する
  - _Boundary: NekozeFix/Session/MainHopGate.swift（受け渡し計測器・初期化のみ。PostureSessionManager呼出点には触れない）_
  - _Requirements: 1.1, 1.2, 1.3_

- [x] 3. 呼出結線と表示書込み最適化を実装する
- [x] 3.1 呼出点へのゲート結線と最新排出と停止再開時の初期化配送を実装する
  - 配送分のみ Main へ渡し、集約分は新規タスクを生成せず最新のみ保持することを確認する
  - 排出時に常に最新の結果で判定継続と表示反映が一括で行われることを確認する
  - 停止・再開後に古い状態による判定の乱れが発生しないことを確認する
  - 事象駆動の受け渡しと周辺振舞が変わらないことを確認する
  - _Boundary: NekozeFix/Session/PostureSessionManager.swift（captureOutput呼出点・排出・初期化配送のみ。MainHopGate判定則・PoseDetectorには触れない）_
  - _Requirements: 2.1, 2.3, 3.1, 4.1, 4.5, 5.4, 6.1, 6.2, 6.3_
- [x] 3.2 表示専用値の不変書込み省略を実装する
  - 画面比率が不変の場合に書込みが省略されることを確認する
  - 画面比率の変化時に表示が変化後の値で更新されることを確認する
  - 判定が参照する値の書込みに影響がないことを確認する
  - _Boundary: NekozeFix/Session/PostureSessionManager.swift（表示書込み最適化のみ。判定継続則・MainHopGate判定則には触れない）_
  - _Requirements: 3.2, 3.3_

- [x] 4. 検証と実測記録を行う
- [x] 4.1 (P) 集約器と計測器の単体テストを拡充する
  - 種別遷移の即時配送・校正中全量・定常間引き境界・最新優先・初期化直後の振舞いが検証されることを確認する
  - 両計数の進行と読出しの複写性が検証されることを確認する
  - _Boundary: NekozeFixTests/MainHopGateTests.swift（受け渡し集約器・受け渡し計測器の単体検証。PostureSessionManager呼出点には触れない）_
  - _Requirements: 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 4.1, 6.2_
- [x] 4.2 (P) 結線と判定・体験の非回帰テストを追加する
  - 排出の最新性と初期化後の振る舞いが検証されることを確認する
  - 削減下での3秒確定・猶予・ホールド則と状態表示・通知停止・復帰挙動が既存テストと合わせて検証されることを確認する
  - _Boundary: NekozeFixTests/PostureSessionManagerTests.swift（呼出統合・表示書込み最適化の結合・非回帰検証。MainHopGate判定則・PoseDetectorには触れない）_
  - _Requirements: 3.1, 3.2, 3.3, 4.2, 4.3, 4.4, 5.1, 5.2, 5.3, 6.1, 6.3_
- [ ] 4.3 実機計測シナリオの結果を記録する _Blocked: 実機（iOS Device）が必要な計測であり、シミュレータ環境では実行不可。人手による実機計測待ち_

  - 通常・暗転・不在・復帰・猫背・長時間シナリオの受け渡し頻度・待ち時間・CPU使用率・通知遅延・復帰時間が記録されることを確認する
  - 確定から再生が0.5秒以内であることが実測で確認されることを確認する
  - 実測していない効果の記載がなく未計測項目が明記されることを確認する
  - _Requirements: 5.2, 7.1, 7.2, 7.3_

## Implementation Notes

- レビュー対応（code-review 2軸）：`submit` の4分岐重複は `shouldDeliver` 純粋判定への抽出で解消。`submit` 4引数は design Service Interface 準拠のため `Submission` 型化は見送り
- レビュー対応（Spec c）：排出待ちは初回集約起点（最長待ち）に修正。無効時刻の配送は起点を残さない。定期ログに受け渡し計数を同梱し Req 7.1 の長期記録をログ系列で追えるようにした
- レビュー対応（Spec a）：削減下の猶予・ホールド・背景初期化・校正復帰・Motion/暗転/間引き計数不変の非回帰テストを追加。通知音・遅延破棄運用は実機／設定由来のため対象外
- レビュー対応（Spec b）：フェーズ鏡像・数値既定・排出方針・計測寿命の判断は `docs/adr/0022-hop-gate-wiring.md` に記録。能動排出なし・`校正` 表記維持の根拠を含む
- 実機計測（4.3）の記録源：5秒定期ログの `hopSubmits/hopDelivers/hopCoalesced/hopLastWait` 系列を用いる
