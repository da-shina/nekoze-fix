# カメラプリセットの VGA 切替（垂直画角の確保）

## 概要

横向き使用時に肩が画角外となり検出不能になる問題を受け、`AVCaptureSession.Preset.high` (720p) から `.vga640x480` (4:3) に切り替える。ADR 0009 を supersede する。

## 詳細

- 720p (16:9) は 4:3 センサーの上下を切り落とすため、横向きでは垂直画角が足りず肩が画角外になる。VGA (4:3) はセンサー全高を使うため、同一幅で約33%縦に広く写る。
  根拠は Apple 公式ドキュメント `AVCaptureSession.hardwareCost` の記述："Some formats use the full sensor (4:3) and others a crop (16:9)"（https://developer.apple.com/documentation/avfoundation/avcapturesession/hardwarecost）。センサーがランドスケープネイティブであることは WWDC23 10106 でも言及されている。
- Vision の姿勢推定は内部でネットワーク入力サイズまで縮小するため、640x480 でも検出精度への影響は軽微と見込む（実機検証で確認）。
- NFR 8.1（15fps以上）はバッファ縮小によりむしろ余裕ができる。
- 非対応機種では `.high` に退行する（`canSetSessionPreset` で実行時判定）。
- プレビューは `.resizeAspect` のため歪まず、レターボックス表示になる。可視化のアスペクト補正はバッファ実寸から動的算出のため対応不要。

## Considered Options

- `.high` 維持＋離隔ガイダンス: 肩が物理的に写らない問題は解決しない（却下）
- 向き連動の動的切替: セッション再構成が必要で実装コスト・不安定要因が高い（却下）
- `.inputPriority`（フル解像度 4:3）: 画角は最大だがバッファ巨大で消費電力・発熱増。VGA で不足なら再検討

## Follow-up

- [x] 実機（iPhone 13 mini / iPad 9th の横向き）で肩の検出可否を確認 → 腕上げなしで検出OK、骨格-プレビュー重なりOK、レターボックス表示OK
- 精度低下が観測された場合は本 ADR を再改訂する
