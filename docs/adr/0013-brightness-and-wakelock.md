# 画面暗転モードの輝度制御

## 概要

暗転中は画面輝度を 0.0 に設定し、isIdleTimerDisabled = true で wake lock を維持する。暗転復帰時に元の輝度値を復元する。

## 詳細

- 暗転中: UIScreen.main.brightness = 0.0、UIApplication.shared.isIdleTimerDisabled = true
- 復帰時: 元の輝度値を PostureSessionManager のプロセス内メモリに保持し復元
- バックグラウンド移行時: isIdleTimerDisabled = false。輝度は復元せず、ユーザーの最終操作をそのまま反映

## Considered Options

- 0.1 に設定: 完全黒としない案 → OS がスリープに入り監視が途絶えるリスク
- 完全黒 + wake lock: バッテリー消費が大きい → 0.0 が監視継続に必要
- **プロセス内メモリ (B を選択)**: UserDefaults で永続化せず、復帰時の輝度はユーザーの最終操作（Control Center 変更等）をそのまま反映 → 暗転中の一時的な輝度変更のみ管理