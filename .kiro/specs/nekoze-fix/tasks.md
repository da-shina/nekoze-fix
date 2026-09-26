# Tasks: nekoze-fix

## 1. Foundation: project setup and test infrastructure

- [x] 1.1 Xcode project setup
  - Create `NekozeFix.xcodeproj` with iOS 16+ deployment target
  - Configure SwiftUI lifecycle with `NekozeFixApp.swift` entry point
  - Set up folder structure: Types, Domain, Services, Session, UI, Resources, Tests
  - Observable completion: project builds with no errors
  - _Requirements: 1.1, 3.1_

- [x] 1.2 Test infrastructure setup
  - Create `NekozeFixTests` target with XCTest
  - Configure testable imports for Domain layer unit tests
  - Observable completion: test target runs and reports 0 tests passing
  - _Requirements: (all via domain tests)_

## 2. Core: Domain layer (pure functions)

- [x] 2.1 (P) PostureAnalyzer — gravity-based angle calculation and near-side selection
  - Implement concrete `PostureAnalyzer` struct: `analyze(frame:verticalVector:slouchThresholdDegrees:distanceMetric:slouchDistanceThresholdPercent:previousNearSide:)`
  - Near-side selection by shoulder x-coordinate (left < right → .left)
  - Angle calculation: dot product between shoulder-to-ear vector and `verticalVector`, acute 0-90 degrees
  - Confidence < 0.3 excluded, keypoint deficiency → `insufficientKeypoints`
  - One-side detection: detected side treated as near-side automatically
  - Observable completion: unit test verifies near-side selection and gravity-based angle calculation (Requirement 4.1)
  - _Boundary: PostureAnalyzer_
  - _Requirements: 3.5, 4.1, 4.5, 4.6_
  - _Depends: 1.2_

- [x] 2.2 (P) TimedConditionGate — N-second continuous condition gate
  - Implement concrete `TimedConditionGate` struct with `requiredDuration`, `tick(isConditionMet:now:)`, `reset()`
  - `isConditionMet == true` only accumulates; false resets to zero immediately
  - Calibration instance: 5.0s required; Slouch confirm instance: 3.0s required
  - Observable completion: unit test verifies 5s continuous triggers true, <5s does not
  - _Boundary: TimedConditionGate_
  - _Requirements: 2.3, 2.4, 4.2, 4.3_
  - _Depends: 1.2_

- [x] 2.3 (P) CalibrationLogic — stable reference posture acquisition
  - Implement concrete `CalibrationLogic` struct with `start()`, `ingest(sample:presence:now:points:)`, `CalibrationProgress`
  - Accumulate only when `personDetected` and `AngleSample` is valid; accumulate visualization points alongside angles
  - Posture instability reset: angle delta > 5 degrees or near-side flip or person dropout over 1.0s resets accumulation（dropoutTolerance 内の脱落は蓄積時間を凍結）
  - Completion: average of near-side angles becomes reference posture; final frame points returned as `referencePoints`
  - Re-run: `start()` overwrites previous reference
  - Observable completion: unit test verifies 5s stable → completed, angle change > 5° → reset
  - _Boundary: CalibrationLogic_
  - _Requirements: 2.1-2.7_
  - _Depends: 1.2, 2.1_

## 3. Core: Services layer

- [x] 3.1 (P) CameraSessionManager — front camera session and permissions
  - Implement concrete `CameraSessionManager` class with `authorization`, `captureSession`, `requestAuthorization()`, `start()`, `stop()`, `applyVideoOrientation(_:)`
  - Preset `.high` (720p); `AVCaptureVideoDataOutput` on serial queue
  - `startRunning`/`stopRunning` on background queue
  - `.denied` authorization → start throws, UI shows settings guide
  - Observable completion: authorization flow works and `.authorized` enables camera start
  - _Boundary: CameraSessionManager_
  - _Requirements: 1.1, 1.2, 3.1, 7.1, 8.1_
  - _Depends: 1.1_

- [x] 3.2 (P) PoseDetector — Vision body pose keypoint extraction
  - Implement concrete `PoseDetector` class: `detect(sampleBuffer:orientation:) -> PoseFrame?`
  - Uses `VNDetectHumanBodyPoseRequest`; confidence < 0.3 → nil keypoint
  - Empty observation → nil（Session は 0.5 秒猶予 `personMissingGracePeriod` 経過後に personMissing 確定）
  - Latest-frame-only dispatch when queue backlogged (target 15fps+)
  - 複数人物時は画面中央に最も近いバウンディングボックスの人物のみ選択（FR 4.7）
  - Observable completion: unit test verifies keypoint filtering and nil on empty observation
  - _Boundary: PoseDetector_
  - _Requirements: 2.5, 3.4, 4.5, 4.7, 8.1_
  - _Depends: 1.2_

- [x] 3.3 (P) AlertPlayer — sound notification with playback category
  - Implement concrete `AlertPlayer` class with `configureSession()`, `playOnce()`, `startRepeating()`, `stop()`
  - `.playback` category + `.duckOthers`; preloads sound on `configureSession()`
  - `playOnce` on confirmed slouch; `startRepeating` at one-audio-loop interval from last notification
  - Next notification stops previous sound if still playing (overwrite policy)
  - `stop()` on improvement or monitoring stop (immediate)
  - Observable completion: unit test verifies playOnce fires within 0.5s of confirmed slouch
  - _Boundary: AlertPlayer_
  - _Requirements: 5.1-5.4, 8.2_
  - _Depends: 1.1, 1.2_

- [x] 3.4 (P) DeviceOrientationMonitor — rotation detection with 5s timeout
  - Implement concrete `DeviceOrientationMonitor`: `currentVideoOrientation`, `isRotating`
  - `UIDevice.beginGeneratingDeviceOrientationNotifications()` monitoring
  - Rotation start → `isRotating = true`; 5s no change → `isRotating = false`
  - Observable completion: unit test verifies isRotating transitions correctly
  - _Boundary: DeviceOrientationMonitor_
  - _Requirements: 7.1, 7.2_
  - _Depends: 1.2_

- [ ] 3.5 (P) GravityVectorProvider — Core Motion gravity integration
  - Implement `GravityVectorProvider` using `CMMotionManager`
  - Provide real-time gravity vector $\vec{g} = (g_x, g_y, g_z)$ in device coordinate system
  - Project $\vec{g}$ onto the image plane based on current `videoOrientation` to get $\vec{v}_{vertical}$
  - Observable completion: unit test verifies correct vertical vector for portrait and landscape orientations
  - _Boundary: GravityVectorProvider_
  - _Requirements: 4.1_
  - _Depends: 1.2, 3.4_

- [x] 3.6 (P) SettingsStore — threshold and monitoring flag persistence
  - Implement concrete `SettingsStore` class with `slouchThresholdDegrees`, `isMonitoringEnabled`
  - UserDefaults persistence for threshold degrees (3.0...20.0) + monitoring flag only
  - Observable completion: unit test verifies clamping and persistence
  - _Boundary: SettingsStore_
  - _Requirements: 4.4, 8.2_
  - _Depends: 1.2_

## 4. Core: Session layer

- [ ] 4.1 PostureSessionManager — session state machine and single source of truth
  - Implement concrete `PostureSessionManager: ObservableObject` with `snapshot: SessionSnapshot`
  - Integrate `GravityVectorProvider` to supply $\vec{v}_{vertical}$ to `PostureAnalyzer`
  - State machine: awaitingPermission → calibrating → idle → monitoring → rotating
  - Dim mode as flag; monitoring continues when dimmed
  - PersonMissing determined after 0.5s grace period; reset gates immediately
  - Background → stop; foreground → resume if `SettingsStore.isMonitoringEnabled` true and calibrated
  - Observable completion: unit test verifies all state transitions and gravity-based analysis flow
  - _Boundary: PostureSessionManager_
  - _Requirements: 2.*, 3.*, 4.*, 5.*, 6.*, 7.*, 8.*_
  - _Depends: 2.1, 2.2, 2.3, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

## 5. Integration: UI layer

- [x] 5.1 (P) RootView — phase-based screen switching
  - Switch between Permission / Calibration / Monitor views based on `snapshot.phase`
  - Observable completion: app launches and shows PermissionView on first run
  - _Boundary: RootView_
  - _Requirements: 1.1, 1.2, 10.1_
  - _Depends: 4.1_

- [x] 5.2 (P) PermissionView — camera authorization UI
  - First launch triggers system permission dialog
  - Denied → settings guide + "retry" button
  - Observable completion: denied state shows settings guide with retry button
  - _Boundary: PermissionView_
  - _Requirements: 1.1, 1.2_
  - _Depends: 4.1_

- [x] 5.3 (P) CalibrationView — calibration guidance and progress
  - 3-second hold instruction; detection status; accumulation timer display
  - Shared `PostureOverlayView(mode: .current)` displays shoulders, ears, and near-side judgment line
  - Observable completion: calibration completes after 3s stable, shows completion
  - _Boundary: CalibrationView_
  - _Requirements: 2.1-2.6_
  - _Depends: 4.1_

- [ ] 5.4 (P) MonitorView — monitoring, dim mode, sensitivity control
  - Preview, good/slouch/personMissing display; start/stop buttons
  - Sensitivity slider; dim mode button (enterDimMode/exitDimMode)
  - Dim mode: black screen (brightness 0.0 + wake lock); tap to exit
  - Observable completion: monitor view shows posture state and responds to dim button
  - _Boundary: MonitorView_
  - _Requirements: 3.1-3.4, 4.4, 6.1-6.3_
  - _Depends: 4.1, 3.1, 3.3_

- [x] 5.5 (P) CameraPreviewView — AVCaptureVideoPreviewLayer SwiftUI wrapper
  - `UIViewRepresentable` wrapping `AVCaptureVideoPreviewLayer`
  - Hidden when dimmed
  - Observable completion: preview visible during monitoring, hidden during dim mode
  - _Boundary: CameraPreviewView_
  - _Requirements: 3.2, 6.2_
  - _Depends: 3.1_

- [ ] 5.6 (P) PostureOverlayView — visualization of landmarks and vertical guideline
  - Implement `PostureOverlayView` to draw shoulders, ears, and the current judgment line
  - Draw the **physical vertical guideline** starting from the near-shoulder point, extending in the $\vec{v}_{vertical}$ direction
  - Support `.reference` (gray, fixed) and `.current` (colored, real-time) modes
  - Observable completion: vertical line correctly follows device tilt in real-time during monitoring
  - _Boundary: PostureOverlayView_
  - _Requirements: 4.8_
  - _Depends: 4.1, 5.5_

## 6. Integration: E2E flows

- [ ] 6.1 E2E critical path integration test
  - Verify: permission → 5s calibration → monitoring start → 3s slouch held → notification → improvement stop → dim mode → tap restore
  - Observable completion: full flow completes without errors in integration test
  - _Requirements: 1.1-10.1_
  - _Depends: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_

## 7. Validation

- [ ] 7.1 Performance verification
  - Measure keypoint processing >= 15fps with `.high` preset (NFR 8.1)
  - Measure notification latency <= 0.5s from confirmed slouch (NFR 8.2)
  - Observable completion: performance test results meet NFR targets
  - _Requirements: 8.1, 8.2_
  - _Depends: 6.1_

- [ ] 7.2 Battery consumption verification (manual/measured)
  - 1-hour continuous monitoring <= 15% battery (NFR 9.1)
  - Dim mode consumption lower than normal mode (NFR 9.2)
  - Observable completion: measured battery consumption meets NFR 9.1/9.2
  - _Requirements: 9.1, 9.2_
  - _Depends: 6.1_

## 8. Validation: Gravity Vector Robustness (New)

- [ ] 8.1 Gravity Vector Unit Tests
  - Mock `GravityVectorProvider` to return various tilt vectors
  - Verify `PostureAnalyzer` returns correct `PostureVerdict` regardless of device orientation
  - Observable completion: all tilt scenarios (portrait, landscape, tilted) produce consistent verdict for same relative posture
  - _Boundary: PostureAnalyzer, GravityVectorProvider_
  - _Requirements: 4.1_
  - _Depends: 2.1, 3.5_

