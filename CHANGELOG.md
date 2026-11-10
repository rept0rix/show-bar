# Show Bar versions

Show Bar is a macOS app. It brings Windows features to the Mac.

## 2.0.3

- Smoother Dock window previews:
  - Previews open after a short 180 ms pause and switch between apps in 90 ms, with a crossfade instead of a flash.
  - Cards keep a stable order, so windows no longer shuffle under the pointer.
  - Thumbnails are laid out at their final size first, so they no longer flash or get squeezed while switching apps.
  - The last good Dock geometry is kept during Dock animations, and hidden (auto-hide) Dock icons are only targeted when visible.
  - Sharper thumbnails (up to 640 px) and a larger preview cache.
- Clicking a preview brings exactly that window forward, without jumping back to the app's previous window or desktop.
- Clipboard history (⌃⌥V) redesigned as a frosted-glass panel with a header, item count, Esc to close, and Clear All.
- Command-Tab switcher and screenshot shelf use the same frosted-glass look.
- Desktop tour redesigned with illustrated steps and one consistent glass button style.
- New automated tests for Dock preview behavior (`scripts/test-previews.sh`, `swift test`).

## 2.0.2

- Interactive Desktop Tour & Permission Setup:
  - Top-centered Apple Frosted Glass HUD (`880x410`) pinned reliably on screen without auto-hiding during system interactions (`hidesOnDeactivate = false`).
  - 100% reliable clickability with zero hit-test clipping.
  - Redesigned permissions setup with spacious stacked layout, 42px colored squircles, clear status indicators (`Active & Ready ✅`), and 1-click system settings links.
  - Enlarged typography (15pt-22pt) and high-contrast Apple-grade gradient buttons with specular gloss highlight sheen.
  - Tactile 3D keyboard shortcut badges (`⌘ + ⇧ + 3`, `⌃ + ⌥ + V`).
- Dock Window Preview Stability:
  - Eliminated preview flickering and position jitter with 160ms dwell threshold, cursor re-validation, and sticky icon hysteresis.
- Custom Screenshot Save Folder:
  - Choose any custom directory in Settings → Screenshots for saved captures.


- Full-Screen Immersive Desktop Tour ("Show & Do" Live on Mac):
  - Completely redesigned from a heavy modal window into an atmospheric, non-blocking full-screen desktop tour.
  - Transparent passthrough hit-testing allows the user to interact live with their real Mac desktop, menu bar, and Dock while the guide is active!
  - Central floating glassmorphic HUD card with real-time reactive mission detection:
    - Mission 1 (First Screenshot): Explains macOS 4-second disappearing frustration vs Show Bar floating shelf with zero desktop clutter; auto-detects when the user presses ⌘⇧3/⌘⇧4 or clicks the camera.
    - Mission 2 (Multi-Shot Deck & Copy All): Demonstrates screenshot stacking in the corner shelf, 1-click 'Copy All' (paste straight into WhatsApp/Slack), markup, and custom folder save.
    - Mission 3 (Clipboard History ⌃⌥V): Explains losing past copies vs full multi-copy history; auto-detects when ⌃⌥V is pressed.
    - Mission 4 (Dock Window Previews & Snap): Peek inside open windows without switching apps, with instant half-screen snap (⌃⌥← / ⌃⌥→) and background close (X).
    - Mission 5 (Visual ⌘+Tab Switcher & Settings Recap).
  - Ambient glowing bottom aura and top menu bar spotlight pointers.
  - Can be exited or skipped at any time via 'Exit Tour' or Esc key.
- Custom Screenshot Save Location in Settings:
  - Added full folder selection setting in Settings → Screenshots ("Choose Folder…", "Reveal in Finder", "Reset to Desktop").
  - Seamlessly applies to all saved screenshots from the shelf.
- Fixed Dock Window Preview flickering and dancing ("מרצד החלון"):
  - Raised icon switch dwell threshold from 35ms to 160ms with cursor re-validation, preventing rapid popups while moving across adjacent icons.
  - Added sticky icon hysteresis (+8px padding zone) to lock the hovered icon against Dock magnification size oscillations.
  - Eliminated stationary polling re-triggers when the mouse hasn't moved.
  - Introduced generation-tracked thumbnail synchronization (`watchGeneration`) so asynchronous thumbnails from a previous app never overwrite a newly hovered app.

## 1.9.8

- Hands-On Interactive Onboarding Lab ("Show & Do"):
  - Mission 1: Menu Bar spotlight highlighting top-bar icons + live test screenshot action taking a screenshot straight into the floating shelf.
  - Mission 2: Multi-Screenshot stacking in the corner shelf + "Copy All" action + interactive paste box demonstrating zero desktop clutter.
  - Mission 3: Multi-Save Clipboard History (⌃⌥V) interactive sequence with sample data copying and live clipboard shelf opening.
  - Mission 4: Visual ⌘+Tab Switcher showcase comparing native macOS to Show Bar across spaces.
  - Mission 5: Live Dock window previews demonstration with window snapping and close 'X' without switching apps.
  - Mission 6: Complete cheat-sheet recap and final ready state.

## 1.9.7

- Dedicated First-Launch Onboarding Wizard: Automatically welcomes new users with an interactive, 4-step guided journey (Welcome, Feature Showcase, 1-Click Permissions Setup, and Interactive Preview Testing).
- Frictionless Permissions Flow: Guides users through Accessibility and Screen Recording with live real-time status checkmarks and direct 1-click links to macOS System Settings.
- Always Accessible: Reopen the onboarding wizard anytime via "Welcome & Onboarding Guide…" in the top menu bar or from Settings.
- Improved User Education: Crystal-clear explanations of what Show Bar does (Dock previews, ⌘+Tab across spaces, window snapping, clipboard history, and screenshot shelf) eliminating any first-launch confusion.

## 1.9.6

- Fixed UI jitter and moving elements by eliminating redundant view rebuilds in the settings loop and removing unprompted launch sample popups.
- Redesigned permissions onboarding: if permissions are missing, Show Bar opens directly on the Permissions tab with clear 1-click buttons to open macOS System Settings.
- Added a full visual "Features Guide" directly inside the app comparing each feature to native macOS (Dock window previews, Multi-Shot shelf, Clipboard history, Window snapping, Command-Tab).
- Enhanced menu bar icons with informative tooltips showing keyboard shortcuts and feature descriptions.
- Added real-time permission status indicators with automatic live updates.

## 1.9.5

- Added settings options to independently toggle window previews on hover (dock/side screens) and the Command-Tab window switcher.
- When the Command-Tab window switcher is disabled, macOS native Command-Tab works normally while keeping other shortcuts active.
- Added quick toggles for Window Previews and Command-Tab directly in the menu bar menu.

## 1.9.2

- Command-Shift-3 and the menu-bar camera capture only the active screen under the pointer, preventing dual-monitor canvas stitching and blank border gaps.
- Capturing every screen saves each display as its own clean, individual screenshot on the shelf.
- Shelf screenshots support smooth drag-and-drop directly into chats, editors, and other apps.

## 1.9.1

- Opening a screenshot from the shelf opens the full markup editor properly, fixing the white blank screen issue.

## 1.9

- Quick Command-Tab switches to the previous window immediately without getting stuck on screen.
- Choosing a window in Command-Tab accurately raises and focuses that exact window, even when multiple windows of the same app are open.
- Suppresses the native macOS Command-Tab switcher to prevent conflicting double switchers.
- Windows across all Desktops and Spaces are listed with desktop badges, and selecting one switches directly to its Space.

## 1.8

- After an update, Show Bar opens one preview so the window pictures start loading.
- Choosing a window in Command-Tab or on the Dock opens that window, including a chosen WhatsApp window.
- Closing the screenshot editor leaves the picture on the shelf. Opening the editor again shows the picture.

## 1.7

- A screenshot includes Show Bar, so the Dock preview and Command-Tab can be captured.
- Moving along the Dock switches to the next app immediately, including icons at the far ends. The same is true for a Dock on the left, the right, or the bottom.
- When an update is ready, the menu-bar icon keeps a blue dot, and the menu keeps an Update button.

## 1.6

- Admin is no longer in the app menu. Download counts are on a private page.

## 1.5

- Command-Tab follows the app in front. A window that stays above the others, such as Spotify, is no longer stuck first.
- Windows on Desktop 1 and on the other screen are in Command-Tab, not only the desktop in front.
- Command-Shift-3 and Command-Shift-4 work while Command-Tab is open.
- A crop hides the arrow and draws a target that stays on the pointer.
- Screenshots collect in the corner. X on a picture leaves it out. Copy all puts the rest on the clipboard as files, so one paste sends them together.
- Settings has a Shots tab: keep the shelf open, copy and close, save and close, or save and keep it open.
- The menu bar has a camera for the whole screen and a dashed rectangle for a crop.
- A window card can snap that window to the left half and then the right, and copy that window.
- Preview pictures stay inside their cards.

## 1.4

- A screenshot plays the system tick, and the Mac’s own save window stays closed.
- The screenshot preview has a save button. It writes the picture to the Desktop.
- Dock window previews open on hover after launch. A Preview click is no longer required.
- Previews follow the Dock on the left, the right, or the bottom, including after the Dock is moved.
- Settings no longer offers a top Dock. macOS cannot put the Dock there.
- Settings opens with the logo and the version, then a preview, a rating, and a coffee. Dock, shortcuts, permissions, and the app are separate tabs.
- Remove Show Bar is red. It says the app goes to the Trash and has to be installed again.

## 1.3

- A newer GitHub release shows a blue dot on the menu-bar icon, a notification, and an Update / Not now prompt.
- Show Bar replaces itself only when the downloaded app is signed as Show Bar by the same team.
- After each update, Show Bar asks for a rating.
- Admin shows how many times each install disk was downloaded.

## 1.2

- The site and About say this plainly: Show Bar runs on macOS and brings Windows capabilities to the Mac.
- Clipboard history keeps text, links, and screenshots. Control-Option-V opens the list.
- A screenshot copies to the clipboard and does not save a file. The preview stays in the bottom corner until its X is pressed.
- Command-Tab shows real app windows.
- Settings can ask for a store rating. The store link is added when the page exists.

## 1.1

- Previews open beside the Dock icon, and they open faster.
- Move a window to another desktop from its card.
- A white bar under the name marks the window under the pointer.
- Rest on a card for two seconds to peek that window. Click to switch, or leave to put it back.
- Command-Tab shows the windows, newest first, and stays on the screen.
- Settings can move the Dock to the left, right, top, or bottom.
- Show Bar opens when the Mac starts, stays in the menu bar when its window is closed, and can move itself to the Trash.
- Control-Option and the arrows snap the front window to a half, a corner, or the whole screen.
- About in Settings shows the version, these notes, and Naor Yanko's LinkedIn.

## 1.0

- Hover a Dock icon to see that app's windows.
- Click a window to switch to it.
- Close one window, minimize it, or quit the app from the card.
- Choose the preview size, how many windows, and whether names are shown.
