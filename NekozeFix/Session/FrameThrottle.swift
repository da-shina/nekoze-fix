import Foundation

/// 時刻間隔によるVision推論の間引き判定器（同期型・錠なし）。
///
/// 前回推論時刻との間隔が上限間隔以上の場合のみ推論対象とする。
/// 無効時刻（NaN・負・無限大）のフレームは推論対象として扱い、検出機会を保つ。
/// 複数キューからの利用時は `LockedFrameThrottle` を経由し単一の錠で直列化する。
/// 上限切替え（`setLimit(_:)`）と初期化（`reset()`）の割込みは呼出側の直列配送で防ぐ。
///
/// 計数は受動的な加算のみであり、検出結果と呼出順序を変えない。
/// 読出しは値複写であり、永続化と外部送出は行わない。
/// 停止・再開時は `reset()` で判定状態と計数をともに初期化する。
///
/// 設計参照: `.kiro/specs/vision-fps-throttle/design.md`「Session / FrameThrottle FPS計測器」。
/// 既定の上限は暫定値であり、最終選定はタスク3.3の実測比較（現状・15・10FPS）に委ねる。
struct FrameThrottle {
    /// 計測値の値複写。読出し専用の不変スナップショット。
    struct Metrics: Equatable {
        /// `shouldInfer(at:)` の呼出回数。
        var arrivals: Int = 0
        /// 推論対象と判定された回数。
        var inferences: Int = 0
        /// 推論対象外として破棄された回数。
        var drops: Int = 0
        /// `recordInference(duration:)` で記録された推論所要時間の累積（秒）。
        var totalInferenceTime: TimeInterval = 0
    }
    /// 暫定の既定上限FPS。最終選定はタスク3.3の実測比較で行う。
    static let defaultMaxFPS: Double = 15.0

    /// 推論FPSの上限。注入時に定まる。
    private(set) var maxFPS: Double
    /// 上限間隔（秒）。`1.0 / maxFPS` から導出される。
    var minInterval: TimeInterval { 1.0 / maxFPS }

    /// 前回推論対象としたフレームの提示時刻。未推論・初期化直後は nil。
    private var lastInferenceTime: TimeInterval?

    /// 入力到達数・推論実行数・破棄数・推論累積時間。プロセス内メモリのみ。
    private var counters = Metrics()

    /// - Parameter maxFPS: 推論FPSの上限（正の有限値）。不正値は既定値に倒す。
    init(maxFPS: Double = FrameThrottle.defaultMaxFPS) {
        self.maxFPS = Self.normalizeFPS(maxFPS)
    }

    /// 正の有限値のみ採用し、不正値は既定値に倒す。
    private static func normalizeFPS(_ fps: Double) -> Double {
        fps.isFinite && fps > 0 ? fps : FrameThrottle.defaultMaxFPS
    }

    /// 提示時刻が推論対象かを判定する。呼出ごとに1回のみ判定する。
    ///
    /// 呼出ごとに到達数を1加算し、判定結果に応じて推論実行数・破棄数の
    /// いずれかを1加算する。計数は判定結果に影響しない。
    /// - Parameter timestamp: フレームの提示時刻（秒単位）。
    /// - Returns: 推論対象なら true。対象時は前回推論時刻を更新し、
    ///   対象外時と無効時刻時は状態を変えない。
    mutating func shouldInfer(at timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, timestamp >= 0 else {
            noteArrival(inferred: true)
            return true
        }
        guard let last = lastInferenceTime else {
            lastInferenceTime = timestamp
            noteArrival(inferred: true)
            return true
        }
        if timestamp - last >= minInterval - 1e-9 {
            lastInferenceTime = timestamp
            noteArrival(inferred: true)
            return true
        }
        noteArrival(inferred: false)
        return false
    }

    /// 推論所要時間を累積する。判定動作には影響しない。
    ///
    /// `shouldInfer(at:)` 内で時刻を測らない（時計依存を持たせない）ため、
    /// 呼出側が実測した所要時間を渡す。無効値（NaN・負・無限大）は無視する。
    /// - Parameter duration: 推論所要時間（秒単位）。
    mutating func recordInference(duration: TimeInterval) {
        guard duration.isFinite, duration >= 0 else { return }
        counters.totalInferenceTime += duration
    }

    /// 計測値を値複写で読み出す。永続化と外部送出は行わない。
    /// - Returns: 読出し時点の計測値の複写。
    func snapshot() -> Metrics {
        counters
    }

    /// 推論FPSの上限を切り替える。前回推論時刻と計数は維持し、
    /// 次回 `shouldInfer(at:)` から新上限間隔で評価する。
    ///
    /// 検出キュー経由で直列適用すること（判定途中での割込みは
    /// 呼出側の直列配送で防ぐ。本値は同期型のため内部に錠を持たない）。
    /// dim-mode-saving からの判定中切替え受口。
    /// - Parameter fps: 新しい推論FPS上限（正の有限値）。不正値は既定値に倒す。
    mutating func setLimit(_ fps: Double) {
        maxFPS = Self.normalizeFPS(fps)
    }

    /// 判定状態と計数を初期化する（前回推論時刻と全計数をクリア）。
    mutating func reset() {
        lastInferenceTime = nil
        counters = Metrics()
    }

    /// 計数のみを初期化する（前回推論時刻と上限は維持）。
    /// 計測区間の開始時に時刻と計数を同一区間にそろえるための受口
    /// （レビュー指摘 4241621573 対応）。判定動作には影響しない。
    mutating func resetCounts() {
        counters = Metrics()
    }

    /// 到達数に1、判定結果に応じて推論実行数・破棄数のいずれかに1を加算する。
    private mutating func noteArrival(inferred: Bool) {
        counters.arrivals += 1
        if inferred {
            counters.inferences += 1
        } else {
            counters.drops += 1
        }
    }
}

/// `FrameThrottle` の錠付き保持器（Session 所有）。
///
/// 判定（検出キュー）・初期化（専用直列キュー）・計測読出し（Main/Timer）の
/// 全アクセスを単一の錠で直列化する（レビュー指摘 4241621567 対応）。
/// ADR 0021（PoseDetector の錠付き計測器）と同一則。
/// 構造体側は同期型のまま（単体テストは構造体を直接検証する）。
/// 錠で全状態を保護するため `@unchecked Sendable` とする
///（PoseDetector・CameraSessionManager と同一則）。
final class LockedFrameThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var throttle: FrameThrottle

    init(maxFPS: Double = FrameThrottle.defaultMaxFPS) {
        throttle = FrameThrottle(maxFPS: maxFPS)
    }

    /// 提示時刻が推論対象かを判定する（全キューから呼べる）。
    func shouldInfer(at timestamp: TimeInterval) -> Bool {
        lock.withLock { throttle.shouldInfer(at: timestamp) }
    }

    /// 推論所要時間を累積する（判定動作には影響しない）。
    func recordInference(duration: TimeInterval) {
        lock.withLock { throttle.recordInference(duration: duration) }
    }

    /// 計測値を値複写で読み出す。
    func snapshot() -> FrameThrottle.Metrics {
        lock.withLock { throttle.snapshot() }
    }

    /// 推論FPSの上限（読出しのみ）。
    var maxFPS: Double {
        lock.withLock { throttle.maxFPS }
    }

    /// 推論FPSの上限を切り替える。前回推論時刻と計数は維持する。
    func setLimit(_ fps: Double) {
        lock.withLock { throttle.setLimit(fps) }
    }

    /// 判定状態と計数を初期化する（ゲートを開放方向へ倒す冪等操作）。
    func reset() {
        lock.withLock { throttle.reset() }
    }

    /// 計数のみを初期化する（ゲート状態は維持。計測区間の開始専用）。
    func resetCounts() {
        lock.withLock { throttle.resetCounts() }
    }
}
