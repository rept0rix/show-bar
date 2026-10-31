# App Store Connect Listing & ASO Metadata

## Product Page Metadata

- **Name:** Show Bar
- **Subtitle:** Dock Previews & Screen Tools
  *(29 / 30 chars max — high search volume keywords)*
- **Primary category:** Utilities
- **Secondary category:** Productivity
- **Promotional text:**
  Elevate your Mac: Instant window previews on the Dock, quick screen captures, split window snapping, and seamless clipboard history. 100% native, private, and fast.
  *(169 / 170 chars max)*

- **Description:**

Transform how you navigate and manage your workspace on macOS. Show Bar brings Windows-style Dock previews, intuitive window switching, instant screen capture, and effortless clipboard history straight to your Mac.

Built natively in Swift and SwiftUI, Show Bar is ultra-lightweight, lightning fast, and designed to look right at home on macOS Sonoma and macOS Sequoia.

KEY FEATURES:

◆ DOCK WINDOW PREVIEWS
Hover over any running application in your Dock to see live, high-resolution thumbnail previews of all open windows. Switch to, minimize, or close windows directly from the preview card.

◆ POWERFUL COMMAND-TAB SWITCHER
Mac Command-Tab shows app icons; Show Bar shows the actual windows. Easily identify which document or tab you're switching to with instant visual previews.

◆ SMART WINDOW SNAPPING
Tile and organize your windows in seconds. Snap windows to the left half, right half, quarters, or maximize using clean keyboard shortcuts (⌃⌥ + Arrow keys) or the menu bar.

◆ STREAMLINED SCREENSHOTS
Capture your main display or individual screens on demand. Copy directly to your clipboard or save as PNG with a single shortcut (⌘⇧3 / ⌘⇧4).

◆ PRIVACY-FIRST CLIPBOARD HISTORY
Never lose a copied snippet, link, or note. Keep your recent text clippings accessible without sacrificing privacy.

◆ SHOW BAR COMPANION (iPhone & iPad)
Securely control your Mac windows, manage clipboard text, and annotate screenshots directly from your iOS or iPadOS device. Paired with authenticated TLS encryption on your local Wi-Fi, with zero cloud dependency and complete per-device permission control.

PRIVACY & PERFORMANCE BY DESIGN:
• 100% Native: Negligible CPU and memory footprint (under 30MB RAM).
• Local Processing: Screen captures, previews, and clipboard history remain strictly on your Mac.
• No Account Required: Open and use immediately without sign-up, ads, or subscriptions.

- **Keywords (98 / 100 chars max, no spaces):**
  `dock,preview,window,switcher,alt-tab,screenshot,screen,capture,snip,clipboard,history,snap,companion`

- **Support URL:** https://rept0rix.github.io/show-bar/support.html
- **Privacy Policy URL:** https://rept0rix.github.io/show-bar/privacy.html
- **Copyright:** © 2026 Naor Yanko
- **Price:** Free
- **Availability:** All territories

---

## App Review Notes

Show Bar is a native local macOS utility. The reviewer can test all features without an account or network connection.

1. **Window Previews & Dock Hover:** Requires Screen Recording consent to draw live window thumbnails via ScreenCaptureKit, and Accessibility consent to inspect Dock hover position.
2. **Window Snapping & Switcher:** Uses Accessibility APIs to position windows into halves/corners upon user shortcut.
3. **Screenshots & Clipboard:** Fully local on-device utility.
4. **App Privacy:** Show Bar does not track personal identifiers (PII). Anonymous usage milestones (e.g. app launched, feature invoked) may be gathered to diagnose onboarding issues in full compliance with Apple's diagnostic disclosures.
5. **Show Bar Companion:** Allows paired iOS/iPadOS devices on the same local network to control Mac windows and view previews. Uses authenticated TLS 1.2 PSK over Network.framework Bonjour (`_showbar._tcp`). All sharing and remote action switches start disabled by default and require explicit Mac host opt-in. Each companion device is individually identified and can be revoked or customized directly from the Mac.

---

## What's New in This Version (Release Notes)

• Introduced Show Bar Companion for iPhone and iPad: securely pair your devices over local Wi-Fi to manage windows, browse clipboard history, and annotate screenshots.
• Added comprehensive onboarding & clear permission guide with instant live preview testing.
• Enhanced performance and responsiveness of live Dock window thumbnails.
• Streamlined window snapping shortcuts and multi-monitor display handling.
• Privacy and diagnostics improvements to ensure smooth first-time setup.
