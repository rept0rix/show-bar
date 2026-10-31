# Show Bar Companion — revised implementation plan

Reviewed: 29 October 2026. The original Antigravity concept is preserved in that conversation's artifacts. This document is the implementation specification for this repository.

סיכום העדכון: נבנית אפליקציה אמיתית לאייפון ולאייפד לשליטה ב־Mac, עם צימוד מוצפן, סידור חלונות, מדף טקסטים ועריכת צילומים. הוסרו ההבטחות להחלפת מחליף האפליקציות של האייפד ולמעקב אוטומטי אחר הלוח ברקע. השיתוף מופעל במפורש במק, והעיצוב מסתגל לרוחב המסך בלי להסתמך על חומרת קיפול שטרם אומתה. המסמך להלן מפרט את המימוש ואת בדיקות הקבלה.

## What needed correction

The concept mixed control of Mac windows with replacement of iPadOS system features. Those are different products with different permissions. An ordinary iPad app cannot enumerate other apps' windows, capture their contents, replace the global app switcher, or keep a shelf over every app. `UIKeyCommand` supports commands delivered to the app's responders; the OS controls system commands. A Live Activity is not a continuously running clipboard monitor. Advertising clipboard secrets in Dynamic Island would also expose content on locked devices.

The previous desktop bridge also accepted unauthenticated plaintext commands, parsed each TCP read as a complete JSON line, never refreshed state automatically, and called a copy operation “paste”. It was a prototype, not a foundation safe to enable on a network.

References: [Apple keyboard commands](https://developer.apple.com/documentation/uikit/uikeycommand), [local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [TLS pre-shared keys](https://developer.apple.com/documentation/security/sec_protocol_options_add_pre_shared_key(_:_:_:)).

## Product to build

A native iOS 17+ and iPadOS 17+ app that securely controls an explicitly paired Mac running Show Bar. Compact layouts use four tabs; large windows use a sidebar and roomy control surface. Landscape and resized windows adapt by available space. This also provides the useful desk-console layout from the foldable concept without depending on an unverified device or hinge API.

1. **Connection:** discover Bonjour hosts on the local network, paste a high-entropy pairing code displayed on the Mac, reconnect to the same selected Mac, show clear connection errors, and forget saved pairing.
2. **Windows:** live Mac window names and optional previews, select a window, bring it forward, close it with confirmation, and arrange it into halves, quarters, or the available screen. Snap and paste require a selected window. Permissions and stale windows produce explicit results.
3. **Clipboard:** opt-in Mac text/link history and separately enabled clipboard images; an independent local text shelf with explicit Paste/import and composition; search, kind filters, copy locally, copy to Mac, or paste into the selected Mac window. Code whitespace is preserved. Text previews longer than 8192 characters are labeled truncated and cannot be mistaken for the complete original when copying/sending. PNG clipboard images up to 3 MiB / 4000px per dimension are retrieved by opaque item ID, preserving the stored PNG, and can be copied, annotated and shared. No background iOS clipboard reads.
4. **Shots:** opt-in thumbnails from the Mac's current screenshot shelf, fetch an image on demand, copy, drag, share via the system sheet (including AirDrop where available), and annotate a retrieved image using PencilKit. Transfers are optimized JPEGs, at most 2400 pixels on the longest edge and 3 MiB, rather than lossless originals. Clearing the device's exported shots must not silently delete Mac screenshots.
5. **Desk mode:** explicit keep-awake control while the app is active, restored on background/disappearance. In-app keyboard shortcuts navigate sections and arrange Mac windows; the system app switcher remains managed by iPadOS.
6. **Settings and permissions:** a dedicated companion settings sheet distinguishes verified OS permission status from individual Mac grants. It provides persistent preview visibility and window-close confirmation preferences, desk mode, explicit system-settings navigation, confirmed local history clearing, pairing removal and app version. The Mac settings panel exposes each action/share grant independently, connected session names, disconnect-all and reset-all pairing. Demo/offline status never claims that OS permissions were verified.

## Build and ownership

- `Shared/`: versioned Codable protocol, bounded incremental JSON-line decoder, authenticated TLS configuration, pairing-code generation, and Keychain storage. Both app targets compile exactly these sources.
- `Sources/RemoteBridge.swift`: desktop host and native pairing/sharing panel.
- `Companion/Sources/`: native SwiftUI app, Bonjour/network client, local shelf, and PencilKit editor.
- `MacAppStore/project.yml`, `Companion/project.yml`: reproducible XcodeGen projects.
- `Tests/CompanionProtocolTests/`: framing and real TLS handshake tests.
- `Companion/Tests/`, `Companion/UITests/`: client/storage tests and simulator workflow coverage.

## Privacy and operational requirements

- Remote access starts disabled. After the user enables it, focus and arrangement are available by default; window closing, copying/pasting to Mac and every outbound sharing category default off. Nine independent feature grants are enforced on the host and client. Window preview sharing is separate from screenshot sharing; image clipboard sharing also requires clipboard history sharing.
- Missing capability metadata from an older host grants no mutation or image access. Capability updates remove disallowed remote content and cancel affected pending requests; queued host image/snapshot packets carry a revocation epoch. Already exported copies cannot be remotely erased.
- Pairing uses 128 random bits, not a guessable six-digit LAN password. Codes are stored in the platform Keychain. Rotating the Mac's code disconnects peers and invalidates their saved codes. Each device additionally identifies itself with a persistent device ID; individual devices can be revoked, disconnected, or assigned custom permission grants directly from the Mac host without rotating the master pairing code for other devices.
- Network.framework TLS authenticates both peers before application messages. There is no certificate-verification bypass or plaintext fallback. Version 1 uses TLS 1.2 PSK with AES-128-GCM; this cipher does not provide forward secrecy. Individual device revocation is enforced at the protocol layer upon connection.
- Protocol version negotiation, incremental framing, frame limits, connection/handshake/heartbeat timeouts, bounded queues, and command limits prevent unbounded traffic and silent mismatches.
- Every command has an ID and a result. App UI state changes on the main actor; network work uses a private queue. Late callbacks from replaced connections are ignored.
- Clipboard access on iOS is user initiated. The local shelf is bounded and stored with device file protection. Remote snapshots are cleared on disconnect.
- Window previews are transferred only after preview-sharing opt-in and current Screen Recording preflight; screenshot-shelf exports require screenshot-sharing opt-in. Clipboard PNG exports require both clipboard and image-sharing opt-ins. Denied Screen Recording permission never triggers a hidden authorization request.
- Closing a window asks on the companion; the Mac application still handles unsaved-document prompts. No remote shell, arbitrary file paths, global keyboard forwarding, or automatic content publishing is added.

## Acceptance and release gates

- Compile the macOS desktop target, iOS simulator app, and generic physical-device target.
- Verify real TLS matching/wrong-key behavior, fragmented/coalesced frames, binary payloads, malformed frames, version mismatch, and size bounds.
- Verify client state transitions, selected-window commands, demo isolation, local shelf persistence/bounds, and reconnect cancellation.
- Run iPhone and iPad workflows and inspect actual simulator screenshots. Demo screens are labeled sample data and cannot send commands.
- Before distribution, verify pairing and permissions on a physical Mac+iPhone/iPad on the same network, test multiple screens/unsaved documents/AirDrop and Apple Pencil, provide production signing and App Store assets, and review privacy disclosures. Simulator success is not proof of physical-device Bonjour, network permissions, or App Store approval.

## Explicitly outside the supported platform contract

System-wide iPad app switching, arbitrary other-app screenshots on iOS, a shelf over unrelated apps, background clipboard interception, and Dynamic Island clipboard-secret previews are removed from the implementation promise. A fold-specific hinge layout remains a concept until supported hardware/API can be verified. System-wide importing is supported via registered URL scheme (`showbar://shelf/add?text=...`), while explicit text pasting and system image sharing are available in the app. Each device is uniquely tracked with per-device persistent revocation and customizable capability overrides. Rotating the shared master pairing code remains available to reset all devices at once.
