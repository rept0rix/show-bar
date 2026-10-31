# Show Bar Companion

Native iPhone and iPad remote for Show Bar on Mac. Supports iOS/iPadOS 17 and later.

## Run

1. Open `Companion/ShowBarCompanion.xcodeproj` in Xcode (or regenerate with `xcodegen generate --spec Companion/project.yml`). Select `ShowBarCompanion` and an iPhone or iPad simulator/device.
2. Build the updated desktop target from `MacAppStore/ShowBarStore.xcodeproj`, scheme `ShowBar`. Existing release binaries do not include the paired protocol.
3. On the Mac, open the Show Bar menu → **Companion devices…** and enable the companion connection. Copy its pairing code.
4. On the iPhone/iPad, open **Connect**, allow Local Network access, choose that Mac, and paste the code. Both devices need network access to each other; guest/client-isolated Wi-Fi can prevent discovery.
5. Review the Mac's independent action and sharing switches. Focus/arrangement are on after enabling the host; close, copy/paste-to-Mac and all sharing start off. Enable only the features you want. Clipboard images also require clipboard-history sharing. Select a window in **Windows** before arranging or pasting into it.
6. Open the gear **Settings and permissions** on the companion to review OS permission status and Mac grants. Local close-confirmation and preview preferences persist; OS permissions and Mac feature grants are changed on the relevant device.

Use **Try demo** to view labeled sample windows without a Mac. Run with `--demo` to open the same read-only demo for screenshots/tests.

## Features

- Live window list, optional previews, focus/confirmed close, halves/quarters/maximize.
- Explicit local text shelf with search and filters, copy to device/Mac, paste to selected window.
- Mac screenshot shelf, on-demand full image transfer, system sharing/AirDrop, drag and PencilKit annotation.
- Compact tabs and large-screen sidebar, section keyboard shortcuts, explicit keep-awake desk mode.
- TLS pairing, Keychain secrets, bounded protocol and reconnect handling, sharing opt-ins.
- Nine individual action/share grants with server enforcement, live revocation and clear OS permission status.
- Per-device identity tracking, single-device revocation/disconnect, and custom capability overrides with presets (Guest/Read-Only, Window Control, Full Access).
- System-wide text/link import via registered URL scheme (`showbar://shelf/add?text=...` / `url=...`).
- Stored PNG clipboard-image downloads, copying, annotation and system sharing, up to 3 MiB and 4000px per dimension. Truncated text previews are labeled and cannot be sent as complete originals.

The app controls the paired Mac. iPadOS owns its system app switcher and other applications' windows. Networking pauses when the app is backgrounded. Clipboard images are downloaded explicitly from the Mac; screenshot exports use the separate Shots section. You can disconnect, revoke, or customize permissions for an individual device from the Mac settings without rotating the pairing code for other devices. To revoke the shared pairing code for all devices at once, reset it on the Mac.

## Checks

```sh
swift test
xcodebuild -project Companion/ShowBarCompanion.xcodeproj -scheme ShowBarCompanion -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' CODE_SIGN_IDENTITY=- test
xcodebuild -project MacAppStore/ShowBarStore.xcodeproj -scheme ShowBar CODE_SIGNING_ALLOWED=NO build
```

The real desktop bridge also provides an isolated Debug host for integration checks. Compile `scripts/companion-smoke.swift` together with the three `Shared/*.swift` files, then pass the Debug Mac executable to the resulting tool. It spawns its own loopback-only test host with a fresh temporary key, verifies protocol behavior, and terminates it without touching normal app preferences or the installed app.

Simulator tests cover local code and loopback network behavior. Physical-device Bonjour permission prompts, Mac Accessibility/Screen Recording, AirDrop, and Apple Pencil still need a device pass before distribution. Production signing, store listings/screenshots, and App Store submission are separate release steps.

See [revised plan](../docs/companion-plan.md) and [transport decision](../docs/adr/001-companion-transport.md).
