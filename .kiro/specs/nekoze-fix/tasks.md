# Tasks: nekoze-fix

## 1. Foundation: project setup and test infrastructure

- [ ] 1.1 Xcode project setup
  - Create `NekozeFix.xcodeproj` with iOS 16+ deployment target
  - Configure SwiftUI lifecycle with `NekozeFixApp.swift` entry point
  - Set up folder structure: Types, Domain, Services, Session, UI, Resources, Tests
  - Observable completion: project builds with no errors
  - _Requirements: 1.1, 3.1_

- [ ] 1.2 Test infrastructure setup
  - Create `NekozeFixTests` target with XCTest
  - Configure testable imports for Domain layer unit tests
  - Observable completion: test target runs and reports 0 tests passing
  - _Requirements: (all via domain tests)_

## 2. Core: Domain layer (pure functions)

- [ ] 2.1 (P) PostureAnalyzer — angle calculation and near-side selection
  - Implement concrete `PostureAnalyzer` struct (not protocol): `analyze(frame:referenceNearAngleDegrees:slouchDeltaThresholdDegrees:)`
  - Near-side selection by shoulder x-coordinate (left < right → .left)
  - Angle calculation: vector from shoulder to ear vs vertical (0,1), acute 0-90 degrees
  - Confidence < 0.5 filtered out; insufficient keypoints returns `insufficientKeypoints`
  - One-side detection: detected side treated as near-side automatically
  - Observable completion: unit test verifies near-side selection and acute angle calculation
  - _Boundary: PostureAnalyzer_
  - _Requirements: 3.5, 4.1, 4.5, 4.6_
  - _Depends: 1.2_

- [ ] 2.2 (P) TimedConditionGate — N-second continuous condition gate
  - Implement concrete `TimedConditionGate` struct with `requiredDuration`, `tick(isConditionMet:now:)`, `reset()`
  - `isConditionMet == true` only accumulates; false resets to zero immediately
  - Calibration instance: 3.0s required; Slouch instance: 5.0s required
  - Observable completion: unit test verifies 5s continuous triggers true, <5s does not
  - _Boundary: TimedConditionGate_
  - _Requirements: 2.3, 2.4, 4.2, 4.3_
  - _Depends: 1.2_

- [ ] 2.3 (P) CalibrationLogic — stable reference posture acquisition
  - Implement concrete `CalibrationLogic` struct with `start()`, `ingest(sample:presence:now:)`, `CalibrationProgress`
  - Accumulate only when `personDetected` and `AngleSample` is valid
  - Posture instability reset: angle delta > 5 degrees or `personMissing` resets accumulation
  - Completion: average of near-side angles during stable period becomes reference posture
  - Re-run: `start()` overwrites previous reference
  - Observable completion: unit test verifies 3s stable → completed, angle change > 5° → reset
  - _Boundary: CalibrationLogic_
  - _Requirements: 2.1-2.7_
  - _Depends: 1.2, 2.1_

## 3. Core: Services layer

- [ ] 3.1 (P) CameraSessionManager — front camera session and permissions
  - Implement concrete `CameraSessionManager` class with `authorization`, `captureSession`, `requestAuthorization()`, `start()`, `stop()`, `applyVideoOrientation(_:)`
  - Preset `.high` (720p); `AVCaptureVideoDataOutput` on serial queue
  - `startRunning`/`stopRunning` on background queue
  - `.denied` authorization → start throws, UI shows settings guide
  - Observable completion: authorization flow works and `.authorized` enables camera start
  - _Boundary: CameraSessionManager_
  - _Requirements: 1.1, 1.2, 3.1, 7.1, 8.1_
  - _Depends: 1.1_

- [ ] 3.2 (P) PoseDetector — Vision body pose keypoint extraction
  - Implement concrete `PoseDetector` class: `detect(sampleBuffer:orientation:) -> PoseFrame?`
  - Uses `VNDetectHumanBodyPoseRequest`; confidence < 0.5 → nil keypoint
  - Empty observation → nil (Session treats as personMissing)
  - Latest-frame-only dispatch when queue backlogged (target 15fps+)
  - Observable completion: unit test verifies keypoint filtering and nil on empty observation
  - _Boundary: PoseDetector_
  - _Requirements: 2.5, 3.4, 4.5, 8.1_
  - _Depends: 1.2_

- [ ] 3.3 (P) AlertPlayer — sound notification with playback category
  - Implement concrete `AlertPlayer` class with `configureSession()`, `playOnce()`, `startRepeating()`, `stop()`
  - `.playback` category + `.duckOthers`; preloads sound on `configureSession()`
  - `playOnce` on confirmed slouch; `startRepeating` at 30s interval from last notification
  - Next notification stops previous sound if still playing (overwrite policy)
  - `stop()` on improvement or monitoring stop (immediate)
  - Observable completion: unit test verifies playOnce fires within 0.5s of confirmed slouch
  - _Boundary: AlertPlayer_
  - _Requirements: 5.1-5.4, 8.2_
  - _Depends: 1.1, 1.2_

- [ ] 3.4 (P) DeviceOrientationMonitor — rotation detection with 5s timeout
  - Implement concrete `DeviceOrientationMonitor`: `currentVideoOrientation`, `isRotating`
  - `UIDevice.beginGeneratingDeviceOrientationNotifications()` monitoring
  - Rotation start → `isRotating = true`; 5s no change → `isRotating = false`
  - Observable completion: unit test verifies isRotating transitions correctly
  - _Boundary: DeviceOrientationMonitor_
  - _Requirements: 7.1, 7.2_
  - _Depends: 1.2_

- [ ] 3.5 (P) AppLifecycleObserver — foreground/background state
  - Implement as concrete class with `isActive` property, notification center subscription
  - Background → camera stop, audio stop, brightness not restored, `isIdleTimerDisabled = false`
  - Foreground → resume monitoring if `SettingsStore.isMonitoringEnabled` true and calibrated
  - Observable completion: unit test verifies background stops and foreground resumes correctly
  - _Boundary: AppLifecycleObserver_
  - _Requirements: 8.1, 8.2_
  - _Depends: 1.2, 3.1, 3.3_

- [ ] 3.6 (P) SettingsStore — sensitivity and monitoring flag persistence
  - Implement concrete `SettingsStore` class with `sensitivity`, `isMonitoringEnabled`, `slouchDeltaThresholdDegrees()`
  - UserDefaults persistence for sensitivity + monitoring flag only
  - Sensitivity 0.0-1.0 → threshold 20-5 degrees linear mapping (20 - sensitivity * 15)
  - Observable completion: unit test verifies sensitivity-to-threshold mapping
  - _Boundary: SettingsStore_
  - _Requirements: 4.4, 8.2_
  - _Depends: 1.2_

## 4. Core: Session layer

- [ ] 4.1 PostureSessionManager — session state machine and single source of truth
  - Implement concrete `PostureSessionManager: ObservableObject` with `snapshot: SessionSnapshot`
  - State machine: awaitingPermission → calibrating → idle → monitoring → rotating
  - Dim mode as flag (not phase); monitoring continues when dimmed
  - PersonMissing immediate判定; gate reset; dim/rotating suppress display
  - Permission denied → settings guide + retry button; retry calls `requestAuthorization()` again
  - Background → stop; foreground → resume per `isMonitoringEnabled`
  - Observable completion: unit test verifies all state transitions and personMissing suppression in dim/rotating
  - _Boundary: PostureSessionManager_
  - _Requirements: 2.*, 3.*, 4.*, 5.*, 6.*, 7.*, 8.*_
  - _Depends: 2.1, 2.2, 2.3, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

## 5. Integration: UI layer

- [ ] 5.1 (P) RootView — phase-based screen switching
  - Switch between Permission / Calibration / Monitor views based on `snapshot.phase`
  - Launch flow: bootstrap → permission → calibration → monitoring (3 steps max)
  - Observable completion: app launches and shows PermissionView on first run
  - _Boundary: RootView_
  - _Requirements: 1.1, 1.2, 10.1_
  - _Depends: 4.1_

- [ ] 5.2 (P) PermissionView — camera authorization UI
  - First launch triggers system permission dialog
  - Denied → settings guide + "retry" button (calls `requestAuthorization()`)
  - Observable completion: denied state shows settings guide with retry button
  - _Boundary: PermissionView_
  - _Requirements: 1.1, 1.2, Q7_
  - _Depends: 4.1_

- [ ] 5.3 (P) CalibrationView — calibration guidance and progress
  - 3-second hold instruction; detection status; accumulation timer display
  - Person missing message; recalibrate button
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
  - _Requirements: 3.1-3.4, 4.4, 6.1-6.3, Q2, Q15_
  - _Depends: 4.1, 3.1, 3.3_

- [ ] 5.5 (P) CameraPreviewView — AVCaptureVideoPreviewLayer SwiftUI wrapper
  - `UIViewRepresentable` wrapping `AVCaptureVideoPreviewLayer`
  - Hidden when dimmed
  - Observable completion: preview visible during monitoring, hidden during dim mode
  - _Boundary: CameraPreviewView_
  - _Requirements: 3.2, 6.2_
  - _Depends: 3.1_

## 6. Integration: E2E flows

- [ ] 6.1 E2E critical path integration test
  - Verify: permission → 3s calibration → monitoring start → 5s slouch → notification → improvement stop → dim mode → tap restore → background stop → foreground restore
  - Observable completion: full flow completes without errors in integration test
  - _Requirements: 1.1-10.1_
  - _Depends: 5.1, 5.2, 5.3, 5.4, 5.5_

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