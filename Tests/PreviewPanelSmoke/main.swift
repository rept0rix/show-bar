import AppKit
import QuartzCore

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { _ = RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) }
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
func visiblePanels() -> [NSWindow] { app.windows.filter { $0 is PreviewWindow && $0.isVisible } }
func cards(in window: NSWindow) -> [PreviewCardView] { descendants(window.contentView!).compactMap { $0 as? PreviewCardView } }
let hiddenControls = PreviewClickBox(id: 1, bounds: CGRect(x: 0, y: 0, width: 200, height: 150),
                                     close: .zero, minimize: .zero, quit: .zero, desktop: .zero, snap: .zero, shot: .zero)
if case .body? = hiddenControls.part(at: CGPoint(x: 2, y: 2)) {
    print("PASS: invisible controls do not steal clicks near the screen origin")
} else { check(false, "invisible controls do not steal clicks near the screen origin") }
let source = WindowCard(id: 1, pid: 0, title: "First preview", frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
let second = WindowCard(id: 2, pid: 0, title: "Second preview", frame: source.frame)
let third = WindowCard(id: 3, pid: 0, title: "Third preview", frame: source.frame)
let preview = PreviewPanel()
let anchor = CGRect(x: 8, y: 240, width: 60, height: 60)
let icon = NSImage(size: NSSize(width: 64, height: 64))
let image = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
preview.present(cards: [source], anchor: anchor, edge: .left, appIcon: icon)
spin(0.04)
let openingFrame = preview.frameAX
preview.apply([Thumbnail(windowID: 1, image: image)])
preview.sync(cards: [source])
spin(0.24)
let window = visiblePanels().first { $0.contentView is PreviewBackdrop }!
check(window.alphaValue == 1 && preview.isShown, "thumbnail arrival finishes opening without hiding the panel")
check(preview.frameAX.size == openingFrame.size, "thumbnail arrival does not resize the preview")
let firstView = cards(in: window)[0]
let renamed = WindowCard(id: 1, pid: 0, title: "Updated title", frame: CGRect(x: 10, y: 30, width: 800, height: 600))
var selected: WindowCard?
preview.onSelect = { selected = $0 }
preview.sync(cards: [renamed])
check(cards(in: window)[0] === firstView, "title refresh retains the card view")
preview.fire(1, .body)
check(selected?.frame == renamed.frame, "click uses the latest window geometry")
firstView.applyHover(false, dimmed: true)
check(firstView.alphaValue == 1, "moving across cards never dims screenshot pixels")
preview.sync(cards: [renamed, second])
spin(0.24)
check(cards(in: window).contains { $0 === firstView }, "adding a window preserves the existing card")
check(visiblePanels().count == 1, "outgoing snapshot is removed after the crossfade")
preview.hide()
spin(0.03)
preview.present(cards: [second, third], anchor: anchor.offsetBy(dx: 0, dy: 80), edge: .left, appIcon: icon)
spin(0.30)
check(preview.isShown && window.isVisible && window.alphaValue == 1, "reopening cancels the old hide completion")
for index in 0..<10 {
    preview.present(cards: index.isMultiple(of: 2) ? [source] : [second, third],
                    anchor: anchor.offsetBy(dx: 0, dy: CGFloat(index * 12)), edge: .left, appIcon: icon)
    spin(0.025)
}
spin(0.28)
check(visiblePanels().count == 1 && window.alphaValue == 1, "rapid switching leaves one fully visible preview")
check(cards(in: window).count == 2, "rapid switching retains only the final app's cards")
preview.hide()
spin(0.20)
check(!preview.isShown && visiblePanels().isEmpty, "closing removes every preview and snapshot window")
print("Native preview smoke checks passed")
