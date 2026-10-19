#!/usr/bin/env bash
# dim-mode-saving 実機計測のログ中継（手順B）。
# 端末の標準出力に流れる [NekozeFix Metrics] 5秒窓ログをファイルへ保存する。
#
# 使い方:
#   scripts/measure-dim.sh <条件名> [秒数]
# 例:
#   scripts/measure-dim.sh normal 300   # 通常5分で自動打ち切り
#   scripts/measure-dim.sh dim          # 暗転。Ctrl-C まで中継
# 条件名の例: normal / dim / absent / recover / long
#
# 前提: 実機へアプリをインストール済みであること（手順A）。
#   ビルド:  xcodebuild -project NekozeFix.xcodeproj -scheme NekozeFix \
#              -destination 'platform=iOS,name=mini' -derivedDataPath /tmp/nekoze-dd build
#   インストール:
#     xcrun devicectl device install app --device mini \
#       /tmp/nekoze-dd/Build/Products/Debug-iphoneos/NekozeFix.app
#
# 電力は手順Dの別コマンドで取得（アプリ起動中に別シェルで実行）:
#   Xcode → Run → Debug Navigator → Energy Report
#   Average Energy Impact ゲージ評価（Low/High/Very High）と
#   Average Component Utilization の領域別%（Overhead/CPU/GPU/Network/Location/Display）を記録
#   同一端末・同一セッションで通常時と暗転時を同条件（同姿勢・同取得時間）で取得し相対比較する
#   詳細は ADR-0025 と design.md「Testing Strategy」を参照
set -euo pipefail

DEVICE="${DEVICE:-mini}"
BUNDLE="${BUNDLE:-com.nekoze.nekoze-fix}"
OUTDIR="${OUTDIR:-/tmp/nekoze-measure}"

COND="${1:?条件名を指定 (例: normal / dim / absent / recover / long)}"
SECS="${2:-}"

mkdir -p "$OUTDIR"
LOG="$OUTDIR/08-dim-${COND}.log"

echo "→ device=${DEVICE} bundle=${BUNDLE}" >&2
echo "→ log=${LOG}" >&2

launch() {
  xcrun devicectl device process launch --device "$DEVICE" \
    --terminate-existing --console "$BUNDLE"
}

if [[ -n "$SECS" ]]; then
  launch >"$LOG" 2>&1 &
  APP_PID=$!
  ( sleep "$SECS"; kill "$APP_PID" 2>/dev/null ) &
  WATCH_PID=$!
  trap 'kill "$APP_PID" "$WATCH_PID" 2>/dev/null' INT TERM
  wait "$APP_PID" || true
  kill "$WATCH_PID" 2>/dev/null || true
else
  launch | tee "$LOG"
fi

echo "→ saved: $LOG" >&2
echo "→ 主要指標: limitFPS(15/10) motionFreq(30/15/10Hz) judge(g/s/i/a/p) inputFPS/inferFPS/dropRate" >&2
