## Spec Report

### Missing / Partial Requirements
**Req 7.1, 7.2, 7.3 / Req 8.1, 8.2 — 条件別の実測記録** — AC 7.1: "通常モード・暗転モード・長時間人物不在・復帰直後・長時間監視の各条件で電力消費・復帰時間・検出精度を実測値として記録する" — Only 通常 and 暗転 have full power measurements (Energy Report gauge + Component Utilization). 長時間不在 and 復帰直後 have only CPU component (partial). 長時間監視 is completely unmeasured. Return-time and accuracy are unmeasured for ALL 5 conditions. tasks.md explicitly marks 4.2 as "IN PROGRESS".

**Req 2.2 — 暗転時の段階的推論頻度低下 (更なる低下)** — AC 2.2: "画面暗転モードが継続し、かつ人物が長時間検出されない、the NekozeFix shall 推論実行頻度を暗転直後よりさらに低下させる" — Implementation sets FPS limit to 10.0 for BOTH `.dimmed` and `.dimmedAbsent` (PostureSessionManager.swift:474-478). Design explicitly states "長時間不在は上限据置きで更なる低下は実効実行数に委ねるため暗転と同値". However, absent-vision-cost-4-2.md confirms Vision workload actually INCREASES 29% per window (face fallback runs every inference), so "further reduction" is not achieved in practice.

### Scope Creep (Not Asked For)
**NekozeFix/UI/CalibrationView.swift:44-52, NekozeFix/Domain/CalibrationLogic.swift:47-56, NekozeFixTests/CalibrationLogicTests.swift:518-570** — Calibration pause/resume by tap (commits a3014ee, 14e1d7a). Feature allows pausing/resuming calibration countdown via tap on timer with strikethrough indicator. Zero relation to dim-mode-saving spec.

**.kiro/steering/architecture-diagram.md, concurrency-model.md, product.md, roadmap.md, structure.md, tech.md** — Entire steering directory created (commit 7cb1ad6). Project infrastructure docs, not dim-mode-saving feature work. Spec only references existing steering, doesn't require creating it.

**NekozeFix/Session/PostureSessionManager.swift:993-1019** — `startFreqCycleIfEnabled()` temporary frequency cycle helper for motion-frequency spec (5.1), guarded by `-measureFreqCycle` launch argument. Test-only but not in dim-mode-saving scope.

**docs/adr/0024-dim-absent-effective-rate.md, docs/adr/0025-energy-impact-as-power-measurement.md** — ADRs created as supporting docs during implementation. Not deliverables requested by spec.

### Implementation Concerns (Looks Wrong)
**Req 2.2 — "更なる低下" contradicted by implementation** — AC 2.2: "推論実行頻度を暗転直後よりさらに低下させる" — `dimStageFPSLimit` returns 10.0 for both `.dimmed` and `.dimmedAbsent` (PostureSessionManager.swift:474-478). Design acknowledges FPS limit unchanged ("上限据置き") and delegates to "実効実行数". But absent-vision-cost-4-2.md measurements show Vision time per inference doubles (~17ms→~34ms) and window Vision total increases 29% due to mandatory face fallback on every absent frame. The "further reduction" requirement is violated in actual workload.

**Req 2.4 — 3秒確定の意味維持 (implementation correct but fragile)** — AC 2.4: "推論実行頻度を低下させている、the NekozeFix shall 3秒連続確定判定の意味を変更しない" — Gate uses wall-clock time (3 seconds via `TimedConditionGate`), not inference count, so meaning is preserved. However, at 10 FPS the gate sees ~30 inferences vs ~45 at 15 FPS. If upstream ever changed gate to inference-count-based, this would silently break. Current implementation relies on time-based gate which is correct per design.

### Summary
Total findings: 6. Worst issue: **Req 2.2 "更なる低下" is not met in practice** — FPS limit unchanged for long-absent stage, and Vision workload actually increases due to face fallback, directly contradicting the spec's core power-reduction goal for the absent stage. Combined with Req 7/8 measurement gaps (4 of 5 conditions lack full measurements), the spec's verification foundation is incomplete.