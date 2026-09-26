# デバイス回転に自動追従する

縦置き・横置きの両方に対応し、デバイス回転時にカメラ入力の向きとUIを自動調整する。iPadのスタンド使用時は横置きが多いため、縦置きのみの対応では実用的でない。回転中は一時的に猫背判定を停止し、回転完了後に再開することで、不安定なフレームによる誤判定を防止する。

## Considered Options

- 縦置きのみ固定：iPadの横置きスタンド使用に対応できない
- ユーザーが選択：3ステップ以内の操作要件と矛盾する可能性

## 更新 (2026-09-26)

PR #9（fix/aspect-ratio-angle-correction）の commit 40a72f2 で「監視モード中の画面回転をポートレート固定」を導入したが、**撤回**する。全モード（校正・監視・暗転）でデバイス回転に追従する本 ADR の当初方針に戻す。

理由:

- 本 ADR の前提（iPad スタンド使用時は横置きが多い）を損なう。監視中だけ回転できないのは要件 7.1「アプリは縦置き・横置きの両方に対応する」と矛盾する
- 固定は `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` が `.portrait` を返す方式だったが、iPad のマルチタスク（Split View / Slide Over / リサイズ可能ウィンドウ）では戻り値だけでは向きを拘束できず、そもそも保証にならない
- CodeRabbit が提案した `UIRequiresFullScreen` は iOS 12 以降システムが無視する deprecated キー（後継は `UIWindowScene.Configuration.requiresFullScreen`）で採用しても効果がない。マルチタスクを禁止してまで固定を保証する方針は取らない

コード変更: `NekozeFixApp.swift` の `AppDelegate` と、`PostureSessionManager` 内の `lockToPortrait()` / `unlock()` 呼び出しを削除。向きに応じたガイダンス分岐（ADR 0014）は維持される。

再導入しないこと: オーバーレイの座標ずれを理由に監視中の固定を再提案しない。ずれ自体は design.md の「ランドスケープ時のオーバーレイ座標ずれ（受容リスク）」として記録済みで、解消は別課題とする。
