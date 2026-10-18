# Gap Analysis: absent-vision-reduction

## Summary
- **Feature**: `absent-vision-reduction` (P2・提案)
- **Type**: Brownfield extension — integrates with existing `vision-face-conditional`, `dim-mode-saving`, `vision-fps-throttle`, `mainactor-throttle`, `motion-frequency`
- **Key Challenge**: Generalize "長時間不在" from dim-mode-only to mode-agnostic, and throttle face fallback in `PoseDetector` during prolonged absence while preserving ADR-0021's "face-only = person present" semantics.

---

## 1. Current State Investigation

### Key Assets & Architecture Patterns

| Layer | Component | Role | Relevance |
|-------|-----------|------|-----------|
| Services | `PoseDetector` | Body pose + **face fallback** (ADR-0021). Runs face detection on **every** inference when pose fails | **Primary modification target** — must throttle face phase during prolonged absence |
| Session | `PostureSessionManager` | Single writer (`@MainActor`). Orchestrates camera, detection, power stages, metrics | **Integration point** — coordinates prolonged absence state → PoseDetector |
| Session | `DimPowerPolicy` | Pure value type owning power stages (`normal` / `dimmed` / `dimmedAbsent`), absence threshold (default 60s), transitions | **Extension target** — currently dim-mode-only; must generalize absence tracking |
| Session | `FrameThrottle` | Time-interval inference gate (15fps normal / 10fps dim). `setLimit(_:)` receiver | Reused — **not changed** (Req 2.3: inference FPS limit unchanged) |
| Services | `MotionService` | Gravity acquisition frequency (30/15/10 Hz). `setUpdateFrequency(_:)` receiver | Reused — **not changed** |

### Conventions
- **Layering**: Types → Domain → Services → Session → UI (strict one-way)
- **Concurrency**: Detection on `detectionQueue` (serial), `MainActor` hops via `LockedMainHopGate`, shared state protected by `NSLock` (`throttleLock`, `SharedState.lock`)
- **Testing**: Domain pure functions unit-tested; Services via protocol seams; Session integration tests with `@testable`
- **Measurement**: 5s window logs `[NekozeFix Metrics]` (arrivals, inferences, drops, inference time, motion samples). Energy via Xcode Energy Report (ADR-0025)

### Integration Surfaces
- `PoseDetector.detect(sampleBuffer:orientation:)` → called from `captureOutput` on `detectionQueue`
- `PostureSessionManager.updateState(presence:...)` → calls `dimPowerPolicy.tick(isPersonDetected:now:)` on MainActor
- `DimPowerPolicy.tick()` returns new `DimPowerStage` → `applyDimPowerStage()` adjusts FPS limit + motion frequency

---

## 2. Requirements Feasibility Analysis

### Technical Needs from EARS Requirements

| Req | Need | Current State | Gap |
|-----|------|---------------|-----|
| **1.1–1.4** Prolonged absence detection (all modes) | Mode-agnostic absence timer using shared 60s threshold; independent of dim stage transitions | `DimPowerPolicy.tick()` only tracks absence when `stage == .dimmed` (line 71) | **Missing**: absence timer for normal mode; decouple from dim stage |
| **2.1–2.2** Face fallback throttling | Reduce face fallback execution frequency during prolonged absence; vision/window lower than dim stage | `PoseDetector.detect()` runs face phase **every** time pose fails (lines 119–141) | **Missing**: throttling mechanism + signal from Session |
| **2.3** Camera + FPS limit unchanged | Camera frames continue; inference FPS limit stays at stage value (15/10) | `FrameThrottle.setLimit()` used by `applyDimPowerStage()` | ✅ No change needed |
| **2.4** Restore face fallback frequency on exit | Return to per-inference face fallback when prolonged absence ends | Not applicable yet | **Missing**: restore path |
| **3.1–3.4** Preserve "face-only = person present" | Face fallback when executed must yield `.personOnly`; face-only return detected within throttle interval; `personMissing` display rules unchanged | `synthesize()` encodes this (line 79); debounce 0.5s in `updateState` | **Constraint**: throttle interval must be ≤ debounce or return detection handled specially |
| **4.1–4.5** Invariants | 3s confirmation, thresholds, near-side, fallback chain, notifications, camera running | All enforced in `PostureAnalyzer`, `PostureSessionManager`, `AlertPlayer` | ✅ No change; regression tests needed |
| **5.1–5.4** Measurement | Per-condition vision time + Energy Report (same device/session); no estimates | 5s window log exists; dim-mode-saving defines template | ✅ Reuse existing; extend for normal-mode prolonged absence |

### Constraints from Architecture
- **No new dependencies** (Apple frameworks only)
- **No camera stop** (Req 2.3, 4.4 — dim-mode-saving Req 5)
- **No inference FPS limit change** (Req 2.3 — `dimmed`/`dimmedAbsent` both 10fps per ADR-0024)
- **Single writer**: `PostureSessionManager` @MainActor owns `snapshot.isPersonDetected`, `dimPowerPolicy`
- **Detection queue isolation**: `PoseDetector` runs on `detectionQueue`; cannot directly read `@MainActor` state
- **ADR-0021 semantics**: `synthesize(pose:faceBounds:)` must remain `pose ?? (faceBounds != nil ? .personOnly : .absent)` — face fallback when executed must still yield `.personOnly`

---

## 3. Implementation Approach Options

### Option A: Extend `DimPowerPolicy` with Mode-Agnostic Prolonged Absence Tracker

**Description**: Add a parallel "prolonged absence" state machine inside `DimPowerPolicy` that runs in all modes, using the same `absentThreshold`. Expose `isProlongedAbsence: Bool` and `prolongedAbsenceTick(isPersonDetected:now:)` separate from dim-stage `tick()`.

**Files to Modify**:
- `DimPowerPolicy.swift` — add `prolongedAbsenceStart`, `isProlongedAbsence`, new `tickProlongedAbsence()` method
- `PostureSessionManager.swift` — call new tick in `updateState` (all phases), pass `isProlongedAbsence` to `PoseDetector`
- `PoseDetector.swift` — add `setProlongedAbsence(_: Bool)` or pass as param to `detect()`; implement face fallback throttling logic

**Compatibility**:
- ✅ Preserves existing `DimPowerStage` transitions (dim-mode-saving unchanged)
- ✅ Single threshold source (`absentThreshold`)
- ✅ `PoseDetector` gets signal via method param or setter (thread-safe: called from detectionQueue with struct copy)

**Complexity**:
- `PoseDetector` needs to throttle face phase: track last face execution time, skip if within throttle interval
- Throttle interval is a **design decision** (e.g., 2s, 5s, 10s) — affects Req 3.2 (return detection within interval)
- Must ensure throttled face runs still update `Metrics.faceExecutedCount` / `faceTotalTime`

**Trade-offs**:
| ✅ Pros | ❌ Cons |
|---------|---------|
| Minimal new files; reuses existing threshold + timer logic | `DimPowerPolicy` grows dual responsibility (dim stages + mode-agnostic absence) |
| Single source of truth for "is prolonged absence" | `PoseDetector` signature change affects callers (only `PostureSessionManager.captureOutput`) |
| Natural fit: `DimPowerPolicy` already owns absence timing | Throttle interval parameter needs design decision (configurable vs hardcoded) |

---

### Option B: New `ProlongedAbsenceTracker` Value Type (Session Layer)

**Description**: Create `NekozeFix/Session/ProlongedAbsenceTracker.swift` — pure value type owning absence timer, threshold, `isProlongedAbsence`. `DimPowerPolicy` unchanged (dim-mode-only). `PostureSessionManager` owns both and calls tracker in `updateState`.

**Files to Create/Modify**:
- **New**: `ProlongedAbsenceTracker.swift` (Session layer)
- `PostureSessionManager.swift` — add tracker instance, call in `updateState`, pass state to `PoseDetector`
- `PoseDetector.swift` — same as Option A

**Compatibility**:
- ✅ Clean separation: dim stages ≠ prolonged absence
- ✅ `DimPowerPolicy` stays dim-mode-specific (per CONTEXT.md current definition)
- ⚠️ CONTEXT.md defines "長時間不在" as dim-mode-only — **design must update CONTEXT** either way

**Trade-offs**:
| ✅ Pros | ❌ Cons |
|---------|---------|
| Clear single responsibility per type | New file + new integration point in Session |
| Easier to test prolonged absence logic in isolation | Two absence timers running (dim + prolonged) — must ensure consistency |
| Aligns with "prolonged absence is mode-agnostic" requirement | Slight duplication of threshold value (mitigated: tracker takes threshold from DimPowerPolicy or shared constant) |

---

### Option C: Hybrid — Tracker in Session, Minimal `DimPowerPolicy` Change

**Description**: Keep `DimPowerPolicy` as-is (dim stages only). Add `prolongedAbsenceStart: TimeInterval?` directly in `PostureSessionManager` (or a small private struct). Compute `isProlongedAbsence` in `updateState` using shared threshold constant. Pass to `PoseDetector`.

**Files to Modify**:
- `PostureSessionManager.swift` — add `prolongedAbsenceStart`, compute `isProlongedAbsence` in `updateState`, pass to `PoseDetector`
- `PoseDetector.swift` — add throttling logic

**Compatibility**:
- ✅ No change to `DimPowerPolicy` (dim-mode-saving spec unaffected)
- ✅ Minimal new code
- ⚠️ Session accumulates more state (violates "small pure policies" pattern from dim-mode-saving)

**Trade-offs**:
| ✅ Pros | ❌ Cons |
|---------|---------|
| Fastest to implement; no new files | Session becomes less "thin orchestrator", more stateful |
| Zero impact on dim-mode-saving | Harder to unit-test prolonged absence logic in isolation |
| | Threshold duplicated or referenced via `DimPowerPolicy.defaultAbsentThreshold` |

---

### Option D: Face Fallback Throttling Inside `FrameThrottle` (Not Recommended)

**Description**: Extend `FrameThrottle` with a "face fallback throttle" sub-mode. When prolonged absence, `FrameThrottle` signals "skip face this inference".

**Why not**: `FrameThrottle` is about **inference FPS limiting** (time-gate on frame timestamps). Face fallback throttling is a **different policy** (skip Vision face request based on absence state). Mixing conflates concerns and breaks "間引き→条件化" order guarantee (ADR-0022/0024).

---

## 4. Gap Summary & Recommendations

### Requirement-to-Asset Map

| Req | Existing Asset | Gap | Severity |
|-----|----------------|-----|----------|
| 1.1 | `DimPowerPolicy.tick()` | Only runs in `.dimmed` stage | **Missing** |
| 1.2 | `DimPowerPolicy` stage transitions | New state "prolonged absence" not modeled | **Missing** |
| 1.3 | `dimPowerPolicy.restored()` | Only restores dim stage; prolonged absence needs separate reset | **Missing** |
| 1.4 | `DimPowerPolicy.defaultAbsentThreshold` | Shared ✅ | — |
| 2.1 | `PoseDetector.detect()` | No face fallback throttling | **Missing** |
| 2.2 | Measurement logs | Need normal-mode prolonged absence window data | **Partial** |
| 2.3 | `FrameThrottle.setLimit()` | Already used; no change ✅ | — |
| 2.4 | `PoseDetector` + Session coordination | Restore path missing | **Missing** |
| 3.1 | `PoseDetector.synthesize()` | Preserved if face runs ✅ | **Constraint** |
| 3.2 | Debounce (0.5s) in `updateState` | Throttle interval must not cause permanent miss | **Unknown** → Research |
| 3.3 | `PoseDetector.detect()` normal path | No change needed ✅ | — |
| 3.4 | `updateState` display rules | Unchanged ✅ | — |
| 4.1–4.5 | Domain/Session logic | Regression tests needed | **Test Gap** |
| 5.1–5.4 | Metrics log + Energy Report | Extend to normal prolonged absence | **Extend** |

### Effort & Risk Assessment

| Approach | Effort | Risk | Rationale |
|----------|--------|------|-----------|
| **A: Extend DimPowerPolicy** | **M** (3–5 days) | **Medium** | Dual responsibility in one type; `PoseDetector` interface change; throttle interval design |
| **B: New ProlongedAbsenceTracker** | **M** (3–5 days) | **Low** | Clean separation; testable; aligns with existing "small pure policies" pattern |
| **C: Inline in Session** | **S** (1–3 days) | **Medium** | Fast but bloats Session; harder to test; threshold drift risk |

### Recommended Approach: **Option B (New ProlongedAbsenceTracker)**

**Rationale**:
1. **Architectural consistency**: dim-mode-saving introduced `DimPowerPolicy` as pure value type for stage transitions. Prolonged absence is a *different* concept (mode-agnostic) — deserves its own type.
2. **Testability**: Can unit-test absence timer + throttle interaction without camera/dim mode.
3. **CONTEXT.md update**: Requirement explicitly says "design フェーズで CONTEXT.md の該当定義の更新". New type makes the generalization explicit.
4. **Future-proof**: If other specs need prolonged absence (e.g., background monitoring), tracker is reusable.

**Key Design Decisions for Design Phase**:
1. **Throttle interval**: How often to run face fallback during prolonged absence? (e.g., every 2s / 5s / 10s). Must satisfy Req 3.2: face-only return detected within interval. Trade-off: lower frequency = more savings but longer return detection delay.
2. **Signal passing**: `PoseDetector` on `detectionQueue` needs `isProlongedAbsence: Bool`. Options: (a) add param to `detect()`, (b) `PoseDetector.setProlongedAbsence(_:)` with lock, (c) `FrameThrottle`-style config. (a) is simplest and thread-safe (value passed per-call).
3. **Metrics**: Should throttled face executions be counted in `PoseDetector.Metrics`? Yes — `faceExecutedCount` only when actually run; `faceSkippedCount` for throttled skips. Extend `Metrics` with `faceThrottledCount`.
4. **Normal vs Dim prolonged absence**: Same throttle interval? Or different? (Req 2.2 only specifies dim stage comparison).

### Research Items for Design Phase
1. **Throttle interval selection**: Measure vision time vs. return detection latency at candidate intervals (2s, 5s, 10s) on device. Relates to Req 3.2 "間引き間隔の範囲内".
2. **CONTEXT.md terminology**: Finalize "長時間不在" generalization vs. new term. Current CONTEXT defines it as dim-mode-only.
3. **PoseDetector interface**: Whether to add `detect(sampleBuffer:orientation:isProlongedAbsence:)` or separate setter. Affects `captureOutput` call site.
4. **Interaction with `personMissingGracePeriod` (0.5s)**: If throttle interval > 0.5s, face-only person returning during prolonged absence will flicker to `personMissing` between face runs. Is this acceptable? (Req 3.4 says display rules unchanged — flicker is a display change). May need design mitigation (e.g., hold `isPersonDetected=true` during throttle gap when prolonged absence active).

---

## 5. Output Checklist

- [x] Requirement-to-Asset Map with gaps tagged
- [x] Options A/B/C with rationale and trade-offs
- [x] Effort (M) and Risk (Medium/Low) with justification
- [x] Recommendations: **Option B preferred**; throttle interval, signal passing, metrics extension, CONTEXT update flagged for design
- [x] Research items carried forward

---

## 6. Design Synthesis Outcomes (from `/kiro-spec-design`)

### Generalization

- **Mode-agnostic prolonged absence**: Requirements 1.1–1.4, 2.1–2.4 require prolonged absence detection in both normal and dim modes. Instead of extending `DimPowerPolicy` (which owns dim-stage transitions), a separate `ProlongedAbsenceTracker` value type was created. This generalizes the *absence timing* capability while keeping *dim-stage transitions* in `DimPowerPolicy`. The interface `tick(isPersonDetected:now:)` naturally supports both current and future modes.
- **Throttling as a policy**: Face fallback throttling (Req 2.1) is a distinct policy from inference FPS limiting (`FrameThrottle`). The design separates them: `ProlongedAbsenceTracker` owns the throttle interval decision, `PoseDetector` executes the skip. This avoids conflating concerns (Option D rejected).

### Build vs. Adopt

- **Adopted**: Existing `DimPowerPolicy.defaultAbsentThreshold` (60s) for absence threshold — single source of truth, testable via injection.
- **Adopted**: Existing `FrameThrottle` / `MotionService` receivers for FPS/frequency — no new throttle mechanisms built.
- **Built**: `ProlongedAbsenceTracker` (new value type) — no existing component owns mode-agnostic absence timing.
- **Built**: `PoseDetector.detect(isProlongedAbsence:)` parameter — minimal interface change, thread-safe value passing.
- **Built**: `Metrics.faceThrottledCount` — extends existing measurement to capture throttling effectiveness.

### Simplification

- **Removed**: `DimPowerPolicy` extension (Option A) — would create dual responsibility (dim stages + mode-agnostic absence).
- **Removed**: Inline Session state (Option C) — violates "small pure policies" pattern established by `DimPowerPolicy`.
- **Removed**: `FrameThrottle` sub-mode (Option D) — conflates inference FPS limiting with face fallback policy.
- **Flattened**: `ProlongedAbsenceTracker` owns both absence timing AND throttle interval decision (`shouldExecuteFaceFallback`), avoiding a separate "throttle policy" component.
- **Single interval**: Same 5s throttle interval for both normal and dim prolonged absence (Req 2.2 only mandates dim comparison; normal-mode comparison is implicit via measurement). Simplifies implementation and testing.

### Key Design Decisions Recorded

| Decision | Rationale | Traceability |
|----------|-----------|--------------|
| **Option B: New `ProlongedAbsenceTracker`** | Clean separation, testable, aligns with `DimPowerPolicy` pattern | Req 1.1–1.4, 2.1–2.4 |
| **5s throttle interval** | Balance: vision reduction vs return detection latency; satisfies Req 3.2 "within interval" | Req 2.1, 2.2, 3.2 |
| **`detect(..., prolongedAbsenceTracker:)` param** | Tracker 渡しで内部完結；`shouldExecuteAndRecordFaceFallback` で判定・記録をアトミック化 | Req 2.1, 3.1 |
| **`Metrics.faceThrottledCount`** | Distinguishes throttled skips from pose-skip (`faceSkippedCount`) | Req 5.1 |
| **`ProlongedAbsenceTracker` as thread-safe class with `NSLock`** | `MotionService.SharedState` パターン踏襲；MainActor/detectionQueue 両スレッドから安全に変更 | Req 1.1–1.4, 2.1 |
| **`shouldExecuteAndRecordFaceFallback` で判定・記録をアトミック化** | `recordFaceExecution` 脱調問題を解決；PoseDetector 内部で完結 | Req 2.1, 2.4, 3.2 |
| **`faceDetectedHoldActive` ホールド機構** | 顔実行後間引き間隔内は `isPersonDetected=true` 維持；通常モード `personMissing` ちらつき防止 | Req 3.2, 3.4 |
| **Same interval for normal/dim** | Simplifies implementation; Req 2.2 only mandates dim comparison | Req 2.2 |
| **CONTEXT.md generalization** | "長時間不在" rewritten to mode-agnostic; "顔フォールバック間引き" / "顔検出ホールド" added | Boundary Context |

### Risks Carried Forward

1. **Throttle interval validation**: 5s is a starting point; real-device measurement may warrant adjustment (ADR to be updated).
2. **Dual absence tracker consistency**: `DimPowerPolicy` + `ProlongedAbsenceTracker` must receive identical `isPersonDetected`/`now`; verified in integration tests.
3. **ADR creation**: `docs/adr/XXXX-face-fallback-throttling.md` to record interval, hold mechanism, same-interval decision.

---

## 7. Design Review Gate Result

- ✅ Requirements Coverage: All 20 numeric requirement IDs (1.1–1.4, 2.1–2.4, 3.1–3.4, 4.1–4.5, 5.1–5.4) mapped in traceability table
- ✅ Architecture Readiness: Component boundaries explicit (`ProlongedAbsenceTracker`, `PoseDetector`, `PostureSessionManager`), interfaces concrete with Swift signatures
- ✅ Boundary Readiness: Owns/Out-of/Allowed/Revalidation sections fully populated
- ✅ Executability: File Structure Plan has 2 new + 5 modified + 1 ADR concrete paths; no orphan components; parallel-safe (Tracker unit tests independent of PoseDetector/Session tests)
- ✅ Mechanical Checks: All requirement IDs found; Boundary sections non-empty; File Structure Plan concrete; no orphan components