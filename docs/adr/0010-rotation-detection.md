# 回転検知の判定ロジック

## 概要

デバイスの向き変更を検知して回転中フラグを管理する。

## 詳細

- UIDevice.beginGeneratingDeviceOrientationNotifications() で方向変更を監視
- orientation 変化が検出されたら isRotating = true
- 5秒間 orientation が変化しなければ完了とみなす（isRotating = false）
- 完了後にカメラ向きを更新（applyVideoOrientation）

## Considered Options

- タイムアウトなし（採用しなかった）: 変化が継続すると無限に isRotating が続く
- CADisplayLink: 過度に複雑
- UIDeviceOrientationDidChangeNotification の直後の 0.5s 待機: 人間の回転動作には遅すぎる
