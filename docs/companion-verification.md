# Companion verification — 30 October 2026

The companion implementation builds for Mac, the iOS Simulator, and physical iOS devices. Physical-device compilation was performed without distribution signing; it does not constitute installation or an App Store submission.

| Check | Observed result |
| --- | --- |
| macOS `ShowBar` Debug build, including companion server and per-device management UI | Passed |
| iOS simulator application build | Passed |
| iOS physical-device Release build of the final sources | Passed, signing disabled (`arm64-apple-ios17.0`) |
| Shared protocol, feature policy, validated image export, deviceID roundtrip, TLS, and custom capability masking tests | 21 passed |
| Client, real loopback integration, live capability revocation, image replies, persistent deviceID and local shelf tests on iPhone 17 Pro | 25 passed |
| iPad Pro 13-inch unit and integration suite | 25 passed |
| iPhone UI workflows: note creation, read-only demo, Shots, Connect navigation, settings persistence, and system URL scheme import | 5 passed |
| Per-device revocation & individual capability management (inline UI & presets) | Passed |
| URL Scheme (`showbar://shelf/add?text=...`) system-wide import | Passed and tested via XCTest |
| Isolated real Mac bridge integration harness (`companion-smoke`) | Passed: pairing, hello/state, refresh acknowledgment, denied mutations, incompatible version, wrong pairing |
| Property-list validation, resource budgets, whitespace check | Passed |

## Evidence

- `/tmp/showbar-protocol-test.log`
- `/tmp/showbar-companion-smoke.log`
- `/tmp/showbar-companion-mac-build.log`
- `/tmp/showbar-companion-device-build.log`
- `/tmp/showbar-companion-iphone-tests-final.xcresult`: complete successful 18-unit/integration + 3-UI run.
- `/tmp/showbar-companion-permissions-iphone.xcresult`: newer 24 unit/integration tests and the three existing UI workflows passed; the first new settings test failed and was rerun rather than counted as passing.
- `/tmp/showbar-companion-settings-tests.xcresult`: new settings workflow passed on iPad; the iPhone run lost its automation connection and is not counted as passing.
- `/tmp/showbar-companion-settings-iphone-retry.xcresult`: final iPhone settings preference/status test and read-only demo test both passed. The settings test taps the switch control explicitly, waits for its value, reopens the sheet to check persistence, and restores the original preference.
- `/tmp/showbar-companion-layout-tests.xcresult`: final revised window view, passed on both devices. The result summary records one selected test executed on two devices, not two distinct tests.
- `output/companion/iphone-tests/`: initial workflow screenshots and manifest.
- `output/companion/layout-tests/`: final screenshots and device manifest.
- `output/companion/settings-iphone-final/`: passing iPhone settings and demo screenshots. `output/companion/permissions-tests/` includes the passing iPad settings screenshot and evidence of the earlier failed iPhone attempt.
- `output/companion/iphone-windows.png`, `output/companion/ipad-windows.png`: convenient copies of the final screenshots. They show explicitly labeled sample content, without a paired Mac or live thumbnails.

The first cold simulator attempts had launch/registration delays. The older installed iOS 26.5 runtime completed the iPhone suite successfully. The initial combined iPad scheme run reported three passing UI workflows, then stalled in cleanup and was stopped. The final targeted layout run was rerun independently and completed successfully on both devices. No unfinished run is counted as a complete passing suite.

The Mac harness uses the actual `RemoteBridge` in a Debug-only loopback mode. It intentionally exposes no real windows, clipboard or screenshots and denies mutations. Network command delivery is also exercised by the real TLS listener in the iOS integration tests. This verifies transport and routing; it does not establish that Accessibility actions, screen capture, AirDrop or Pencil hardware have been validated on physical devices.

The updated real-host harness verifies an explicit empty capability grant and tests the production feature-policy denial before the test-host mutation safeguard. The image-file tests check byte-preserving PNG export, bounded thumbnails, traversal, symlinks outside the shelf, non-images, byte limits and excessive pixel dimensions. Client integration tests verify that a denied action never reaches the listener and that live revocation clears denied content and cancels pending image requests.

## Remaining release checks

1. Pair a physical iPhone/iPad and Mac on the same network; exercise Local Network permission denial/recovery, network isolation and code rotation.
2. Exercise actual Mac focus, close, halves/quarters/maximize, multiple displays, revoked Accessibility permission and unsaved documents.
3. Check enabled text/image sharing and live previews with Screen Recording permission denied and granted. Confirm transfers are optimized JPEGs up to 2400px / 3 MiB.
4. Verify screenshot annotation, resize/rotation, Apple Pencil, sharing and AirDrop on real hardware.
5. Complete signing, store assets/privacy review and any intended distribution flow. This development change has not been published.
