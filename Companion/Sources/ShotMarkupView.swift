import SwiftUI
import PencilKit
import UIKit

struct ShotMarkupView: View {
    let image: UIImage
    let onSave: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var drawing = PKDrawing()
    @State private var canvasSize = CGSize.zero
    @State private var resetID = UUID()

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let size = fitted(image.size, inside: CGSize(width: max(1, geometry.size.width - 32), height: max(1, geometry.size.height - 100)))
                VStack(spacing: 16) {
                    Text("Draw with a finger or Apple Pencil. Changes stay in this copy.")
                        .font(.caption).foregroundStyle(CompanionStyle.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Spacer(minLength: 0)
                    ZStack {
                        Image(uiImage: image).resizable().scaledToFit()
                        PencilCanvas(drawing: $drawing)
                            .id(resetID)
                    }
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .onAppear { canvasSize = size }
                    .onChange(of: size) { _, newSize in
                        if canvasSize.width > 0, newSize.width > 0 {
                            let scale = newSize.width / canvasSize.width
                            drawing.transform(using: CGAffineTransform(scaleX: scale, y: scale))
                        }
                        canvasSize = newSize
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(CompanionStyle.background)
            .navigationTitle("Annotate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) {
                        drawing = PKDrawing()
                        resetID = UUID()
                    }
                    .disabled(drawing.bounds.isEmpty)
                    Button("Done") { onSave(composite()) }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(CompanionStyle.yellow)
    }

    private func composite() -> UIImage {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let ink = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: image.size.width * image.scale / canvasSize.width)
            ink.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func fitted(_ size: CGSize, inside available: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return available }
        let scale = min(available.width / size.width, available.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

private struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = MarkupCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.delegate = context.coordinator
        canvas.tool = PKInkingTool(.pen, color: .systemYellow, width: 4)
        canvas.drawing = drawing
        context.coordinator.canvas = canvas
        canvas.onWindowChange = { [weak canvas, weak coordinator = context.coordinator] in
            guard let canvas, let coordinator else { return }
            coordinator.picker.addObserver(canvas)
            coordinator.picker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.picker.setVisible(false, forFirstResponder: canvas)
        coordinator.picker.removeObserver(canvas)
        canvas.resignFirstResponder()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawing: PKDrawing
        let picker = PKToolPicker()
        weak var canvas: PKCanvasView?

        init(drawing: Binding<PKDrawing>) { _drawing = drawing }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing = canvasView.drawing
        }
    }
}

private final class MarkupCanvasView: PKCanvasView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onWindowChange?() }
    }
}
