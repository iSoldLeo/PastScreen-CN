# Implementation Plan: Swift 6 Strict Concurrency Migration

## Overview

Migrate PastScreen from Swift 5 concurrency to Swift 6 strict concurrency (`-strict-concurrency=complete`). Zero functionality changes, zero UI changes. The migration follows a phased approach: Sendable value types → CGImage wrapper → @MainActor singletons → CaptureLibrary refactor → ScreenshotService refactor → Actor internal fixes → Compile verification.

## Tasks

- [x] 1. Add Sendable conformance to all value types and enums
  - [x] 1.1 Add `Sendable` to all enums and structs in `CaptureLibraryModels.swift`
    - Add `Sendable` to `CaptureItemCaptureType`, `CaptureItemCaptureMode`, `CaptureItemTrigger`, `CaptureLibrarySort`
    - Add `Sendable` to `CaptureItem`, `CaptureLibraryAppGroup`, `CaptureLibraryTagGroup`, `CaptureLibraryQuery`, `CaptureLibraryStats`, `CaptureLibraryCleanupPolicy`, `CaptureLibraryPreviewCandidate`, `CaptureLibraryOCRReindexCandidate`
    - _Requirements: 1.1, 1.2, 1.10_

  - [x] 1.2 Add `Sendable` to all enums and structs in `AppSettings.swift`
    - Add `Sendable` to `HotKey`, `AppOverride`, `RGBAColor`
    - Add `Sendable` to `ClipboardFormat`, `CaptureClipboardFormat`, `OCRClipboardFormat`, `AppLanguage`
    - _Requirements: 1.3_

  - [x] 1.3 Add `Sendable` to remaining types across other files
    - Add `Sendable` to `PermissionType`, `PermissionStatus` in `PermissionManager.swift`
    - Add `Sendable` to `CaptureTrigger` in `PastScreenApp.swift`
    - Add `Sendable` to `AppCategory` in `ScreenshotService.swift`
    - Add `Sendable` to `WindowHitTestResult`, `WindowCaptureError` in `WindowCaptureCoordinator.swift`
    - Add `Sendable` to `OCRServiceError` in `OCRService.swift`
    - Add `Sendable` to `CaptureLibraryFileStore` in `CaptureLibraryFileStore.swift`
    - Add `Sendable` to `OCRLanguageOption` in `OCRLanguageOption.swift`
    - _Requirements: 1.4, 1.5, 1.6, 1.7, 1.8, 1.9_

- [x] 2. Create SendableCGImage wrapper and new Sendable DTOs
  - [x] 2.1 Create `SendableCGImage` struct and `EdgeInsetValues` struct and `WindowCaptureInfo` struct
    - Create `SendableCGImage` as `@unchecked Sendable` with `let image: CGImage` and `// SAFETY:` comment
    - Create `EdgeInsetValues` struct (`Sendable`) with `top`, `left`, `bottom`, `right` as `CGFloat`, plus `init(_ insets: NSEdgeInsets)` convenience
    - Create `WindowCaptureInfo` struct (`Sendable`) with `image: SendableCGImage`, `windowFrame: CGRect`, `appBundleID: String?`, `appName: String?`, `paddingPoints: EdgeInsetValues`
    - Place these in a new file or in `CaptureLibraryModels.swift` / `WindowCaptureCoordinator.swift` as appropriate
    - _Requirements: 2.1, 2.2, 5.1, 5.2_

  - [x] 2.2 Update `CaptureLibraryAddJob` to use `SendableCGImage` and mark `Sendable`
    - Change `cgImage: CGImage` to `cgImage: SendableCGImage` in `CaptureLibraryAddJob`
    - Add `Sendable` conformance to `CaptureLibraryAddJob`
    - Update `CaptureLibrary.addCapture()` call site to wrap `cgImage` in `SendableCGImage(...)`
    - _Requirements: 2.3, 2.4_

  - [x] 2.3 Update `WindowCaptureCoordinator.captureWindow()` to return `WindowCaptureInfo`
    - Change return type from `WindowCaptureResult` to `WindowCaptureInfo`
    - Flatten `SCWindow`/`SCRunningApplication` into plain `String?` fields at the capture point
    - Update `captureWindow(using:)` overload similarly
    - Keep `WindowCaptureResult` temporarily if needed for internal use, or remove it
    - _Requirements: 5.3_

- [x] 3. Checkpoint - Verify Sendable types compile
  - Ensure all tests pass, ask the user if questions arise.

- [x] 4. Apply @MainActor to singleton classes and remove DispatchQueue.main.async
  - [x] 4.1 Add `@MainActor` to `AppSettings` and `LaunchAtLoginManager`
    - Add `@MainActor` to `AppSettings` class declaration
    - Ensure `normalizeOCRRecognitionLanguages(_:)` stays `nonisolated` (pure function)
    - Add `@MainActor` to `LaunchAtLoginManager` class declaration
    - _Requirements: 3.1, 3.2, 3.5_

  - [x] 4.2 Add `@MainActor` to `HotKeyManager` and fix Combine sinks
    - Add `@MainActor` to `HotKeyManager` class declaration
    - Replace `DispatchQueue.main.async { }` in all `sink` closures with `Task { @MainActor in }` pattern
    - Handle `NSEvent.addGlobalMonitorForEvents` callback isolation (use `MainActor.assumeIsolated` or `Task { @MainActor in }` with SAFETY comment)
    - _Requirements: 3.3, 3.10, 7.1_

  - [x] 4.3 Add `@MainActor` to `PermissionManager` and fix callbacks
    - Add `@MainActor` to `PermissionManager` class declaration
    - Replace `DispatchQueue.main.async { }` in `UNUserNotificationCenter` callback and `checkNotificationPermission()` with `Task { @MainActor in }`
    - Replace `DispatchQueue.main.asyncAfter` in `requestScreenRecording` and `requestAccessibility` with `Task { @MainActor in try? await Task.sleep(...) }`
    - _Requirements: 3.4, 3.10, 3.11, 7.4_

  - [x] 4.4 Add `@MainActor` to `WindowCaptureCoordinator`
    - Add `@MainActor` to `WindowCaptureCoordinator` class declaration
    - No DispatchQueue patterns to clean up in this file
    - _Requirements: 3.6_

- [x] 5. Refactor CaptureLibrary: @MainActor + remove NSLock
  - [x] 5.1 Add `@MainActor` to `CaptureLibrary` and remove NSLock
    - Add `@MainActor` to `CaptureLibrary` class declaration
    - Remove `pendingLock` and `indexingLock` NSLock instances
    - Convert `acquireJobSlot()` / `releaseJobSlot()` to plain `@MainActor` methods (no lock)
    - Convert `acquireIndexSlot()` / `releaseIndexSlot()` to plain `@MainActor` methods (no lock)
    - Mark `enqueue()` operation parameter as `@Sendable`
    - Mark `enqueueIndexing()` operation parameter as `@Sendable`
    - Ensure `Task.detached` closures only capture Sendable values
    - _Requirements: 3.8, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6_

- [x] 6. Checkpoint - Verify CaptureLibrary and singletons compile
  - Ensure all tests pass, ask the user if questions arise.

- [x] 7. Refactor ScreenshotService: @MainActor + clean up DispatchQueue
  - [x] 7.1 Add `@MainActor` to `ScreenshotService` and update `FrozenWindowSnapshot`
    - Add `@MainActor` to `ScreenshotService` class declaration
    - Update `FrozenWindowSnapshot` to use `SendableCGImage` for `image` field
    - Replace `application: SCRunningApplication?` with `appBundleID: String?` and `appName: String?` in `FrozenWindowSnapshot`
    - Mark `FrozenWindowSnapshot` as `Sendable`
    - Update `frozenDisplaySnapshots` dict value type to `SendableCGImage`
    - Mark `AutomationRequest` as `Sendable`
    - _Requirements: 2.5, 2.6, 3.7, 5.4, 5.5_

  - [x] 7.2 Replace all `DispatchQueue.main.async/asyncAfter` in `ScreenshotService`
    - Replace `DispatchQueue.main.asyncAfter(deadline: .now() + X)` with `Task { @MainActor in try? await Task.sleep(nanoseconds:); ... }` in `selectionWindow(_:didSelectRect:)`, `selectionWindow(_:didSelectWindow:)`, `scheduleSelectionCleanup()`, etc.
    - Replace `DispatchQueue.main.async { }` calls that are now redundant under `@MainActor` with direct calls
    - Replace `saveQueue.async { }` with `Task.detached(priority: .utility) { }` for background I/O
    - Replace `DispatchQueue.main.sync { }` in `saveToFileAndGetPath` with proper `@MainActor` access
    - Update `showErrorNotification` to remove `DispatchQueue.main.async` wrapper
    - _Requirements: 3.10, 3.11_

  - [x] 7.3 Update all `ScreenshotService` methods that use `WindowCaptureResult` to use `WindowCaptureInfo`
    - Update `performWindowCapture`, `performAdvancedWindowCapture`, `performOCRWindowCapture` to use `WindowCaptureInfo` fields
    - Update `handleSuccessfulCapture`, `handleAdvancedCapture`, `performOCRFrozenCapture`, `handleEditedImage` to accept `appBundleID: String?` / `appName: String?` instead of `SCRunningApplication?`
    - Update `resolvedAppInfo()` to accept optional strings instead of `SCRunningApplication?`
    - Update all frozen window snapshot creation sites in `captureWindowSnapshot` and `prepareFrozenWindowSnapshotsWithScreenCaptureKit`
    - _Requirements: 5.3, 5.4_

  - [x] 7.4 Add `@MainActor` to `AppDelegate` and clean up DispatchQueue patterns
    - Verify `AppDelegate` has `@MainActor` (may already inherit from `NSObject` + `NSApplicationDelegate`)
    - Replace `DispatchQueue.main.async { }` in `handleScreenshotCaptured`, `requestScreenRecordingIfNeeded`, `requestAllPermissions` with direct calls or `Task { @MainActor in }`
    - Replace `DispatchQueue.main.asyncAfter` in `applicationDidFinishLaunching` (onboarding delay) with `Task { try? await Task.sleep(...) }`
    - _Requirements: 3.9, 3.10, 3.11_

- [x] 8. Fix actor internal isolation and Combine sinks
  - [x] 8.1 Fix `CaptureLibraryWorker.notifyChanged()` isolation
    - Replace `DispatchQueue.main.async { }` in `notifyChanged()` with `Task { @MainActor in }` for fire-and-forget notifications
    - For cases needing ordering guarantees (e.g., after `addCapture`), use `await MainActor.run { }` and make the calling method async
    - Add comments explaining the choice of pattern at each call site
    - _Requirements: 6.1, 6.2, 6.3_

  - [x] 8.2 Fix `CaptureLibraryOCRReindexService` isolation patterns
    - Replace `DispatchQueue.main.async { }` in `runReindexLoop()` with `Task { @MainActor in }`
    - Ensure `sink` closures in `start()` use `Task { @MainActor in }` pattern instead of `.receive(on: DispatchQueue.main)`
    - _Requirements: 6.4, 7.2_

- [x] 9. Add @preconcurrency imports where needed
  - Add `@preconcurrency import ScreenCaptureKit` in files that use `SCWindow`, `SCRunningApplication`, `SCDisplay`, etc.
  - Add `@preconcurrency import Vision` if needed for `VNRecognizeTextRequest`
  - Add comment next to each `@preconcurrency import` explaining the suppression reason
  - Ensure `@preconcurrency import` is NOT used to mask project's own Sendable issues
  - _Requirements: 8.1, 8.2, 8.3_

- [ ] 10. Checkpoint - Full compile verification
  - Ensure all tests pass, ask the user if questions arise.

- [-] 11. Final compile verification and test pass
  - [x] 11.1 Enable `-strict-concurrency=complete` in Swift 5 mode and fix remaining warnings
    - Set `SWIFT_STRICT_CONCURRENCY=complete` in build settings (Swift 5 language mode)
    - Fix any remaining concurrency warnings across all files
    - Ensure zero warnings
    - _Requirements: 9.1_

  - [ ] 11.2 Switch to Swift 6 language mode and verify zero errors
    - Set Swift language version to 6 in build settings
    - Fix any errors that were warnings in Swift 5 mode
    - Ensure zero errors
    - _Requirements: 9.2_

  - [ ] 11.3 Run existing test suite and verify all tests pass
    - Run `xcodebuild test` for `CaptureLibraryDatabaseMigrationTests`, `CaptureLibrarySearchSyntaxParserTests`, `CaptureLibraryTagNormalizerTests`
    - Add `@MainActor` to test classes if needed to match tested types' isolation
    - _Requirements: 9.3_

- [ ] 12. Final checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- This is a pure refactoring — zero functionality changes, zero UI changes
- The correctness properties from the design are all compile-time verifiable (Sendable conformance, @MainActor presence, no NSLock, etc.) and are validated by the compiler under `-strict-concurrency=complete`
- `@unchecked Sendable` is only allowed for `SendableCGImage` with a mandatory `// SAFETY:` comment
- `Task.detached` is intentionally used in `CaptureLibrary.enqueue()` and `ScreenshotService.saveToDiskAsync()` to cut `@MainActor` inheritance for background work
