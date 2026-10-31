import SwiftUI
import UIKit

struct CompanionRemoteView: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var sensitivity: Double = 1.3
    @State private var isKeyboardActive = false
    @State private var activeModifiers: UInt32 = 0
    @FocusState private var isFieldFocused: Bool
    @State private var hiddenInputText: String = ""

    var body: some View {
        VStack(spacing: 12) {
            headerBar

            trackpadSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            mouseButtonsBar

            macKeysBar

            // Hidden text field to capture iOS keyboard inputs including dictation
            ZStack {
                TextField("", text: $hiddenInputText)
                    .focused($isFieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .opacity(0.01)
                    .frame(width: 1, height: 1)
                    .onChange(of: hiddenInputText) { _, newValue in
                        if !newValue.isEmpty {
                            client.sendKeyType(newValue)
                            hiddenInputText = ""
                        }
                    }
            }
            .frame(height: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(CompanionStyle.background.ignoresSafeArea())
    }

    private var headerBar: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(client.isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(client.isConnected ? "Connected to \(client.snapshot?.hostName ?? "Mac")" : "Offline · Connect to Mac")
                    .font(.caption.bold())
                    .foregroundStyle(client.isConnected ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: Capsule())

            Spacer()

            Menu {
                Text("Cursor Sensitivity").font(.caption)
                Button("Slow (1.0x)") { sensitivity = 1.0 }
                Button("Normal (1.3x)") { sensitivity = 1.3 }
                Button("Fast (1.8x)") { sensitivity = 1.8 }
                Button("Extra Fast (2.3x)") { sensitivity = 2.3 }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.white.opacity(0.06), in: Circle())
            }

            Button {
                isFieldFocused.toggle()
            } label: {
                Image(systemName: isFieldFocused ? "keyboard.chevron.compact.down.fill" : "keyboard.fill")
                    .font(.callout)
                    .foregroundStyle(isFieldFocused ? CompanionStyle.yellow : Color.secondary)
                    .padding(8)
                    .background(isFieldFocused ? CompanionStyle.yellow.opacity(0.15) : Color.white.opacity(0.06), in: Circle())
            }
        }
    }

    private var trackpadSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(spacing: 8) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.white.opacity(0.15))
                Text("Trackpad")
                    .font(.callout.bold())
                    .foregroundStyle(Color.white.opacity(0.2))
                Text("1-finger tap: Left click • 2-finger tap: Right click\n2-finger drag: Scroll")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.25))
            }
            .allowsHitTesting(false)

            TrackpadGestureRepresentable(
                sensitivity: sensitivity,
                onMove: { dx, dy in
                    client.sendMouseMove(dx: dx, dy: dy)
                },
                onClick: { button in
                    let generator = UIImpactFeedbackGenerator(style: button == "right" ? .medium : .light)
                    generator.impactOccurred()
                    client.sendMouseClick(button: button, type: "click")
                },
                onScroll: { dx, dy in
                    client.sendMouseScroll(dx: dx, dy: dy)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var mouseButtonsBar: some View {
        HStack(spacing: 12) {
            Button {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                client.sendMouseClick(button: "left", type: "click")
            } label: {
                Text("Left Click")
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                client.sendMouseClick(button: "right", type: "click")
            } label: {
                Text("Right Click")
                    .font(.callout.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var macKeysBar: some View {
        VStack(spacing: 8) {
            // Modifiers & essential keys
            HStack(spacing: 6) {
                modifierButton("esc", code: 53)
                modifierButton("tab", code: 48)

                toggleModifierButton("⌘", mask: 1)
                toggleModifierButton("⌥", mask: 2)
                toggleModifierButton("⌃", mask: 4)
                toggleModifierButton("⇧", mask: 8)

                keyButton("⌫", code: 51)
                keyButton("↵", code: 36)
            }

            // Arrow keys & utilities
            HStack(spacing: 6) {
                keyButton("Space", code: 49)

                Spacer()

                keyButton("◀", code: 123)
                keyButton("▲", code: 126)
                keyButton("▼", code: 125)
                keyButton("▶", code: 124)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }

    private func keyButton(_ title: String, code: UInt16) -> some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            client.sendKeyPress(keyCode: code, modifiers: activeModifiers, keyAction: "press")
            // Reset active modifiers after key press
            activeModifiers = 0
        } label: {
            Text(title)
                .font(.system(.caption, design: .monospaced).bold())
                .frame(minWidth: 32)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func modifierButton(_ title: String, code: UInt16) -> some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            client.sendKeyPress(keyCode: code, modifiers: activeModifiers, keyAction: "press")
        } label: {
            Text(title)
                .font(.system(.caption, design: .monospaced).bold())
                .frame(minWidth: 32)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func toggleModifierButton(_ symbol: String, mask: UInt32) -> some View {
        let isActive = (activeModifiers & mask) != 0
        return Button {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            if isActive {
                activeModifiers &= ~mask
            } else {
                activeModifiers |= mask
            }
        } label: {
            Text(symbol)
                .font(.system(.callout, design: .monospaced).bold())
                .frame(minWidth: 32)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(isActive ? CompanionStyle.yellow.opacity(0.3) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isActive ? CompanionStyle.yellow : .primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isActive ? CompanionStyle.yellow : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Low Latency Trackpad Gesture Representable
private struct TrackpadGestureRepresentable: UIViewRepresentable {
    let sensitivity: Double
    let onMove: (Float, Float) -> Void
    let onClick: (String) -> Void
    let onScroll: (Float, Float) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        pan.minimumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.numberOfTouchesRequired = 1
        view.addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.numberOfTouchesRequired = 2
        view.addGestureRecognizer(twoFingerTap)

        singleTap.require(toFail: twoFingerTap)
        pan.require(toFail: singleTap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.sensitivity = sensitivity
        context.coordinator.onMove = onMove
        context.coordinator.onClick = onClick
        context.coordinator.onScroll = onScroll
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sensitivity: sensitivity, onMove: onMove, onClick: onClick, onScroll: onScroll)
    }

    final class Coordinator: NSObject {
        var sensitivity: Double
        var onMove: (Float, Float) -> Void
        var onClick: (String) -> Void
        var onScroll: (Float, Float) -> Void

        init(sensitivity: Double,
             onMove: @escaping (Float, Float) -> Void,
             onClick: @escaping (String) -> Void,
             onScroll: @escaping (Float, Float) -> Void) {
            self.sensitivity = sensitivity
            self.onMove = onMove
            self.onClick = onClick
            self.onScroll = onScroll
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)

            if gesture.numberOfTouches == 2 {
                // Two-finger scroll
                let factor: Float = 2.0
                let dx = Float(translation.x) * factor
                let dy = Float(translation.y) * factor
                onScroll(dx, dy)
            } else if gesture.numberOfTouches == 1 {
                // Single-finger cursor move
                let dx = Float(Double(translation.x) * sensitivity)
                let dy = Float(Double(translation.y) * sensitivity)
                onMove(dx, dy)
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            onClick("left")
        }

        @objc func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
            onClick("right")
        }
    }
}
