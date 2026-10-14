import Foundation

/// Main受け渡し前段の三条件ゲート（値型・同期型・錠なし）。
///
/// 検出キュー上の `captureOutput` から Task 生成直前に申請を受け、
/// 定常 pose 連続のみ表示更新間隔で間引きする。検出種別の遷移・
/// 非 pose 結果・校正フェーズ中・画面比率変化時は間隔にかかわらず配送する。
/// 不通過分は呼出点の単一スロットに最新のみ保持される前提であり、
/// ゲート自体は検出内容を保持しない（種別・時刻・比率の前回値のみ保持）。
///
/// 計数は判定点に内包し、読出しは値複写で行う。計測の有無で配送挙動は変わらない。
/// 設計参照: `.kiro/specs/mainactor-throttle/design.md`「Session / MainHopGate」。
enum DetectionKind: Equatable {
    case pose
    case personOnly
    case absent
}

/// ゲート判定用の軽量フェーズ view。校正蓄積則自体は所有しない。
enum GatePhase: Equatable {
    case calibrating
    case monitoring
}

enum HopDecision: Equatable {
    case deliver
    case coalesce
}

struct MainHopGate {
    /// 計測値の値複写。読出し専用の不変スナップショット。
    struct Metrics: Equatable {
        /// `submit` の呼出回数。
        var submits: Int = 0
        /// 配送と判定された回数。
        var delivers: Int = 0
        /// 集約（単一スロット保持）と判定された回数。
        var coalesced: Int = 0
        /// 直近の排出待ち時間（秒）。集約後の初回配送時に、
        /// 初回集約から排出までの間隔を記録する。集約未発生時は 0。
        var lastDrainWait: TimeInterval = 0
    }

    /// 表示更新間隔（秒）。注入時に定まり、判定中に変わらない。
    /// 0.5秒系グレースより十分小さい値を取る（research 参照）。既定 0.1秒。
    static let defaultDisplayInterval: TimeInterval = 0.1
    /// 画面比率の変化判定の許容誤差。微小差は不変とみなす。
    static let aspectTolerance: CGFloat = 1e-3

    /// 画面比率が変化したかを判定する（許容誤差付き等価）。
    /// ゲート内の配送判定と Main 側の書込み省略判定で単一化する。
    static func aspectChanged(_ old: CGFloat, _ new: CGFloat) -> Bool {
        abs(old - new) > Self.aspectTolerance
    }

    private let displayInterval: TimeInterval
    private var lastDeliverTime: TimeInterval?
    private var lastKind: DetectionKind?
    private var lastAspectRatio: CGFloat?
    private var counters = Metrics()
    /// 初回集約の時刻（排出待ち時間の起点）。配送時に消費し nil に戻す。
    private var pendingSince: TimeInterval?

    init(displayInterval: TimeInterval = MainHopGate.defaultDisplayInterval) {
        if displayInterval.isFinite, displayInterval > 0 {
            self.displayInterval = displayInterval
        } else {
            self.displayInterval = MainHopGate.defaultDisplayInterval
        }
    }

    /// 配送可否を判定する。三条件ゲート（タスク2.1）:
    /// - 校正フェーズ中は全量配送し、校正蓄積の到達を欠落させない
    /// - 検出種別の遷移と非 pose 結果は表示更新間隔にかかわらず配送する
    /// - 画面比率の変化時は表示更新間隔にかかわらず配送する
    /// - 定常 pose 連続のみ表示更新間隔で間引きする
    /// - 無効時刻（NaN・負・無限大）の申請は配送側に倒し、基準時刻を進めない
    ///
    /// 配送時は前回配送時刻・前回検出種別・前回画面比率を更新する。
    /// 集約時は計数のみ進め、判定基準（時刻・種別・比率）は変えない。
    /// 計数は判定点で取りこぼしなく進む（タスク2.2）。
    mutating func submit(
        kind: DetectionKind,
        phase: GatePhase,
        aspectRatio: CGFloat,
        at now: TimeInterval
    ) -> HopDecision {
        guard now.isFinite, now >= 0 else {
            // 無効時刻はスロット排出済みとみなし、待ち時間の起点を残さない。
            pendingSince = nil
            noteDecision(delivered: true)
            return .deliver
        }
        if shouldDeliver(kind: kind, phase: phase, aspectRatio: aspectRatio, now: now) {
            deliver(kind: kind, aspectRatio: aspectRatio, at: now)
            return .deliver
        }
        // 待ち時間は初回集約を起点とする（最長待ちの記録）。
        if pendingSince == nil {
            pendingSince = now
        }
        noteDecision(delivered: false)
        return .coalesce
    }

    /// 配送条件の純粋判定（状態を変えない）。
    /// 校正中全量・非 pose・種別遷移・比率変化・初回・間隔経過のいずれかで配送する。
    private func shouldDeliver(
        kind: DetectionKind,
        phase: GatePhase,
        aspectRatio: CGFloat,
        now: TimeInterval
    ) -> Bool {
        if phase == .calibrating { return true }
        if kind != .pose { return true }
        if let last = lastKind, last != kind { return true }
        if let lastAR = lastAspectRatio, Self.aspectChanged(lastAR, aspectRatio) { return true }
        guard let lastTime = lastDeliverTime else { return true }
        return now - lastTime >= displayInterval - 1e-9
    }

    /// 計測値を値複写で読み出す。永続化と外部送出は行わない。
    func snapshot() -> Metrics {
        counters
    }

    /// 配送時の判定基準の更新と計数の進行を一本化する。
    /// 集約を経た配送では、初回集約から排出までの待ち時間を記録する。
    private mutating func deliver(kind: DetectionKind, aspectRatio: CGFloat, at now: TimeInterval) {
        lastDeliverTime = now
        lastKind = kind
        lastAspectRatio = aspectRatio
        var wait = counters.lastDrainWait
        if let since = pendingSince {
            wait = max(0, now - since)
            pendingSince = nil
        }
        noteDecision(delivered: true, lastDrainWait: wait)
    }

    /// 判定結果に応じて申請数・配送数・集約破棄数のいずれかを1加算する。
    /// 計数は判定結果に影響しない。
    private mutating func noteDecision(delivered: Bool, lastDrainWait: TimeInterval? = nil) {
        counters.submits += 1
        if delivered {
            counters.delivers += 1
        } else {
            counters.coalesced += 1
        }
        if let lastDrainWait {
            counters.lastDrainWait = lastDrainWait
        }
    }

    /// 判定状態と計数を初期化する（停止・再開経路から検出キューへ配送される）。
    mutating func reset() {
        lastDeliverTime = nil
        lastKind = nil
        lastAspectRatio = nil
        pendingSince = nil
        counters = Metrics()
    }
}
