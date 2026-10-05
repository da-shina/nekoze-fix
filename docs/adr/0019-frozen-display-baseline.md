# 監視中の表示基準線の凍結

監視中の表示基準線（`snapshot.referenceVector` の緑/グレー線）は、校正完了時点の向きに凍結する。人物ありの毎フレーム上書きによる微振動を防ぐためである。可変なのは肩点起点の耳-肩角度（黄線と基準線のなす角）と肩ドット位置のみとする。判定の `acuteAngle` 計算に使う基準ベクトルはライブ天方向のまま変えない（表示のみ凍結）。

## Considered Options

- 判定も含めて凍結：表示と判定の一致は保てるが、デバイス傾きへの追従が再校正まで止まり、見逃しが増える
- 新フィールド追加（例 `frozenReferenceVector`）：明示的だが状態が増え、灰色参照線との二重管理になる
- monitoring中のみ上書き停止（採用）：1ガードで両オーバーレイが同時に凍結し、回転・解決元変化の再校正では calibratingに戻った瞬間に自動で解凍→完了時に再凍結される

## Consequences

- `PostureSessionManager.processDetection` は `phase != .monitoring` のときのみ `referenceVector` を更新する
- `applyCalibrationCompletion` の変更なし（完了時点のライブ値がそのまま凍結値になる）
- デバイス傾きは再校正完了後の新凍結値で吸収する。表示と判定に一時乖離が生じうる
- 回帰テストは `ReferenceVectorFreezeTests`、受渡し単一解決は `ReferenceVectorHandoffTests`（calibrating前提）が保証する
