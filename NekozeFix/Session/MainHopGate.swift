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
        let submits: Int
        /// 配送と判定された回数。
        let delivers: Int
        /// 集約（単一スロット保持）と判定された回数。
        let coalesced: Int

        init(submits: Int = 0, delivers: Int = 0, coalesced: Int = 0) {
            self.submits = submits
            self.delivers = delivers
            self.coalesced = coalesced
        }
    }

    /// 表示更新間隔（秒）。注入時に定まり、判定中に変わらない。
    /// 0.5秒系グレースより十分小さい値を取る（research 参照）。既定 0.1秒。
    static let defaultDisplayInterval: TimeInterval = 0.1
    /// 画面比率の変化判定の許容誤差。微小差は不変とみなす。
    static let aspectTolerance: CGFloat = 1e-3

    private let displayInterval: TimeInterval
    private var lastDeliverTime: TimeInterval?
    private var lastKind: DetectionKind?
    private var lastAspectRatio: CGFloat?
    private var counters = Metrics()

    init(displayInterval: TimeInterval = MainHopGate.defaultDisplayInterval) {
        if displayInterval.isFinite, displayInterval > 0 {
            self.displayInterval = displayInterval
        } else {
            self.displayInterval = MainHopGate.defaultDisplayInterval
        }
    }

    /// 配送可否を判定する（骨格段階: 初回は配送、以後の詳細則はタスク2.1で実装）。
    mutating func submit(
        kind: DetectionKind,
        phase: GatePhase,
        aspectRatio: CGFloat,
        at now: TimeInterval
    ) -> HopDecision {
        .deliver
    }

    /// 計測値を値複写で読み出す。永続化と外部送出は行わない。
    func snapshot() -> Metrics {
        counters
    }

    /// 判定状態と計数を初期化する（停止・再開経路から検出キューへ配送される）。
    mutating func reset() {
        lastDeliverTime = nil
        lastKind = nil
        lastAspectRatio = nil
        counters = Metrics()
    }
}
