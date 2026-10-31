import SwiftUI
import UIKit
import Combine

struct CompanionRemoteView: View {
    @EnvironmentObject private var client: CompanionClient
    @AppStorage("Companion.remote.sensitivity") private var sensitivity: Double = 2.4
    @State private var isKeyboardActive = false
    @State private var isScreenViewActive = false
    @State private var screenImage: UIImage? = nil
    @State private var isScreenLoading = false
    @State private var typingBuffer = ""
    @State private var activeModifiers: UInt32 = 0
    @State private var screenTimer: AnyCancellable? = nil

    var body: some View {
        VStack(spacing: 10) {
            headerBar

            if isScreenViewActive {
                screenMirrorCard
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isKeyboardActive {
                liveTypingCard
                    .transition(.opacity)
            }

            trackpadSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            mouseButtonsBar

            macKeysBar

            // Hidden high-reliability key input view capturing delete/backspace and text
            RemoteKeyInputRepresentable(
                isActive: $isKeyboardActive,
                typingBuffer: $typingBuffer,
                onTextChange: { text in
                    typingBuffer.append(text)
                    client.sendKeyType(text)
                },
                onDeleteBackward: {
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                    if !typingBuffer.isEmpty {
                        typingBuffer.removeLast()
                    }
                    // Mac virtual key code 51 is kVK_Delete (Backspace)
                    client.sendKeyPress(keyCode: 51, modifiers: 0, keyAction: "press")
                },
                onReturn: {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    typingBuffer.append("\n")
                    // Mac virtual key code 36 is kVK_Return
                    client.sendKeyPress(keyCode: 36, modifiers: 0, keyAction: "press")
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(CompanionStyle.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: isScreenViewActive)
        .animation(.easeInOut(duration: 0.2), value: isKeyboardActive)
        .onDisappear {
            screenTimer?.cancel()
            screenTimer = nil
        }
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

            // Screen Mirror toggle button
            Button {
                isScreenViewActive.toggle()
                if isScreenViewActive {
                    refreshScreen()
                    startScreenPolling()
                } else {
                    screenTimer?.cancel()
                    screenTimer = nil
                }
            } label: {
                Image(systemName: isScreenViewActive ? "display.trianglebadge.exclamationmark" : "display")
                    .font(.callout)
                    .foregroundStyle(isScreenViewActive ? CompanionStyle.yellow : Color.secondary)
                    .padding(8)
                    .background(isScreenViewActive ? CompanionStyle.yellow.opacity(0.15) : Color.white.opacity(0.06), in: Circle())
            }

            // Sensitivity menu
            Menu {
                Text("Cursor Sensitivity & Speed").font(.caption)
                Button("Slow (1.5x)") { sensitivity = 1.5 }
                Button("Normal (2.4x) · Recommended") { sensitivity = 2.4 }
                Button("Fast (3.2x)") { sensitivity = 3.2 }
                Button("Ultra Fast (4.2x)") { sensitivity = 4.2 }
                Button("Max Speed (5.2x)") { sensitivity = 5.2 }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.white.opacity(0.06), in: Circle())
            }

            // Keyboard toggle button
            Button {
                isKeyboardActive.toggle()
            } label: {
                Image(systemName: isKeyboardActive ? "keyboard.chevron.compact.down.fill" : "keyboard.fill")
                    .font(.callout)
                    .foregroundStyle(isKeyboardActive ? CompanionStyle.yellow : Color.secondary)
                    .padding(8)
                    .background(isKeyboardActive ? CompanionStyle.yellow.opacity(0.15) : Color.white.opacity(0.06), in: Circle())
            }
        }
    }

    private var screenMirrorCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(CompanionStyle.yellow.opacity(0.3), lineWidth: 1)
                )

            if let screenImage {
                Image(uiImage: screenImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 13))
            } else if isScreenLoading {
                VStack(spacing: 6) {
                    ProgressView().tint(.white)
                    Text("Connecting to Mac Screen...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "display")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Tap to refresh Mac screen")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: 180)
        .overlay(alignment: .topTrailing) {
            Button {
                refreshScreen()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.6), in: Circle())
            }
            .padding(6)
        }
    }

    private var liveTypingCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.cursor.ibeam")
                .foregroundStyle(CompanionStyle.yellow)

            Text(typingBuffer.isEmpty ? "הקלד כאן (כולל הכתבה קולית)..." : typingBuffer)
                .font(.subheadline)
                .foregroundStyle(typingBuffer.isEmpty ? Color.white.opacity(0.3) : .primary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            if !typingBuffer.isEmpty {
                Button {
                    typingBuffer = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                keyButton("Esc", code: 53)
                keyButton("Tab", code: 48)

                toggleModifierButton("⌘", mask: 1)
                toggleModifierButton("⌥", mask: 2)
                toggleModifierButton("⌃", mask: 4)
                toggleModifierButton("⇧", mask: 8)

                keyButton("Space", code: 49)
                keyButton("Del", code: 51)
                keyButton("↵", code: 36)

                // Arrows
                modifierButton("◀", code: 123)
                modifierButton("▲", code: 126)
                modifierButton("▼", code: 125)
                modifierButton("▶", code: 124)
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 38)
    }

    private func keyButton(_ title: String, code: UInt16) -> some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            client.sendKeyPress(keyCode: code, modifiers: activeModifiers, keyAction: "press")
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

    private func refreshScreen() {
        guard client.isConnected else { return }
        isScreenLoading = (screenImage == nil)
        client.requestScreenFrame { data in
            isScreenLoading = false
            if let data, let image = UIImage(data: data) {
                self.screenImage = image
            }
        }
    }

    private func startScreenPolling() {
        screenTimer?.cancel()
        screenTimer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                if self.isScreenViewActive && self.client.isConnected {
                    self.refreshScreen()
                }
            }
    }
}

// MARK: - Dedicated Low-Latency Key Input View
private struct RemoteKeyInputRepresentable: UIViewRepresentable {
    @Binding var isActive: Bool
    @Binding var typingBuffer: String
    let onTextChange: (String) -> Void
    let onDeleteBackward: () -> Void
    let onReturn: () -> Void

    func makeUIView(context: Context) -> RemoteKeyInputTextField {
        let field = RemoteKeyInputTextField()
        field.delegate = context.coordinator
        field.onDelete = onDeleteBackward
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.textColor = .clear
        field.tintColor = .clear
        field.backgroundColor = .clear
        return field
    }

    func updateUIView(_ uiView: RemoteKeyInputTextField, context: Context) {
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onDeleteBackward = onDeleteBackward
        context.coordinator.onReturn = onReturn

        if isActive && !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        } else if !isActive && uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onTextChange: (String) -> Void
        var onDeleteBackward: () -> Void
        var onReturn: () -> Void

        init(_ parent: RemoteKeyInputRepresentable) {
            self.onTextChange = parent.onTextChange
            self.onDeleteBackward = parent.onDeleteBackward
            self.onReturn = parent.onReturn
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.isEmpty {
                onDeleteBackward()
                return false
            } else if string == "\n" {
                onReturn()
                return false
            } else {
                onTextChange(string)
                return false
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // Handled when user dismisses
        }
    }
}

private final class RemoteKeyInputTextField: UITextField {
    var onDelete: (() -> Void)?

    override func deleteBackward() {
        super.deleteBackward()
        onDelete?()
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
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.numberOfTouchesRequired = 1
        singleTap.delegate = context.coordinator
        view.addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.numberOfTouchesRequired = 2
        view.addGestureRecognizer(twoFingerTap)

        singleTap.require(toFail: twoFingerTap)

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

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
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

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            let velocity = gesture.velocity(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)

            if gesture.numberOfTouches == 2 {
                // Two-finger smooth scroll
                let factor: Float = 3.5
                let dx = Float(translation.x) * factor
                let dy = Float(translation.y) * factor
                onScroll(dx, dy)
            } else if gesture.numberOfTouches == 1 {
                // Single-finger cursor move with dynamic pointer acceleration
                let speed = sqrt(Double(velocity.x * velocity.x + velocity.y * velocity.y))
                let accel: Double
                if speed < 250 {
                    accel = 1.0
                } else if speed < 1400 {
                    accel = 1.0 + ((speed - 250) / 1150) * 1.8
                } else {
                    accel = min(2.8 + ((speed - 1400) / 1200) * 1.4, 4.2)
                }

                let dx = Float(Double(translation.x) * sensitivity * accel)
                let dy = Float(Double(translation.y) * sensitivity * accel)
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
