import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CompanionShotsView: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var loadingID: String?
    @State private var preview: ShotPreview?
    @State private var shareImages: ShareImages?
    @State private var preparingAll = false
    @State private var batchProgress: String?
    @State private var batchID: UUID?
    @State private var collectionTask: Task<Void, Never>?
    @State private var notice: String?

    private var shots: [BridgeShot] { client.capabilities.shareScreenshots ? client.snapshot?.shots ?? [] : [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Captured. Ready to go.").font(.title2.weight(.bold))
                    Text("Screenshots from your Mac, ready to mark up or share.")
                        .font(.subheadline).foregroundStyle(CompanionStyle.secondary)
                }
                if client.isConnected, client.snapshot?.permissions.screenRecording == false {
                    PermissionNote(title: "Screenshot access needs permission", detail: "On your Mac, enable Show Bar in System Settings → Privacy & Security → Screen Recording, then restart Show Bar.")
                }
                if client.isConnected, !client.capabilities.shareScreenshots {
                    PermissionNote(title: "Screenshot sharing is off on your Mac", detail: "Enable Share screenshots in Show Bar → Companion devices on your Mac. This setting can only be changed there.")
                }
                HStack {
                    ShelfSectionTitle(title: "Shot shelf", detail: "\(shots.count) SHOTS")
                    Button { client.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(!client.isConnected || client.isDemo)
                        .accessibilityLabel("Refresh Mac screenshots")
                }
                if shots.isEmpty {
                    ShelfEmptyState(symbol: "viewfinder", title: "A clear space for your captures", detail: client.isConnected ? "Enable screenshot sharing in Show Bar → Companion devices on your Mac. Take a screenshot and keep it in the Mac shelf." : "Connect your Mac to see the screenshots it shares with you.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                        ForEach(shots) { shot in
                            shotCard(shot)
                        }
                    }
                    HStack(spacing: 16) {
                        Button("Share all", systemImage: "square.and.arrow.up") { collectAll(copy: false) }
                            .buttonStyle(.borderedProminent).foregroundStyle(.black)
                        Button("Copy all", systemImage: "doc.on.doc") { collectAll(copy: true) }
                            .buttonStyle(.bordered)
                        if preparingAll { ProgressView().tint(CompanionStyle.cyan) }
                    }
                    .disabled(!client.isConnected || client.isDemo || !client.capabilities.shareScreenshots || preparingAll || loadingID != nil)
                    if let batchProgress {
                        Text(batchProgress)
                            .font(.caption).foregroundStyle(CompanionStyle.cyan)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(CompanionStyle.cyan)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                PermissionNote(title: "Share on your terms", detail: "Open a shot to copy, annotate with a finger or Apple Pencil, or share through AirDrop. Drag an opened shot into another app on iPad.")
                Text("Transfers use optimized JPEG copies, up to 2,400 pixels on the longest edge. Originals stay on your Mac.")
                    .font(.caption).foregroundStyle(CompanionStyle.secondary)
            }
            .padding(22)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .refreshable { client.refresh() }
        .onDisappear {
            collectionTask?.cancel()
            collectionTask = nil
            batchID = nil
            batchProgress = nil
            preparingAll = false
            client.cancelShotRequests()
        }
        .sheet(item: $preview) { shot in
            ShotDetailView(image: shot.image)
        }
        .sheet(item: $shareImages) { images in
            CompanionShareSheet(items: images.images)
        }
    }

    private func shotCard(_ shot: BridgeShot) -> some View {
        Button {
            loadingID = shot.id
            notice = nil
            client.requestShot(shot.id) { data in
                loadingID = nil
                if let data, let image = UIImage(data: data) {
                    preview = ShotPreview(image: image)
                } else {
                    notice = "This shot is no longer available. Refresh the shelf and try again."
                }
            }
        } label: {
            ShelfCard {
                VStack(alignment: .leading, spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(CompanionStyle.background)
                        if let data = shot.thumbnail, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().padding(5)
                        } else {
                            Image(systemName: "photo").font(.largeTitle).foregroundStyle(CompanionStyle.secondary)
                        }
                        if loadingID == shot.id {
                            RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.5))
                            ProgressView().tint(CompanionStyle.yellow)
                        }
                    }
                    .frame(height: 160)
                    .clipped()
                    HStack {
                        Text("Screenshot").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(CompanionStyle.cyan)
                    }
                    Text(shot.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption2).foregroundStyle(CompanionStyle.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!client.isConnected || client.isDemo || !client.capabilities.shareScreenshots || loadingID != nil || preparingAll)
        .accessibilityLabel("Open screenshot from \(shot.date.formatted(date: .abbreviated, time: .shortened))")
    }

    private func collectAll(copy: Bool) {
        guard !preparingAll else { return }
        preparingAll = true
        notice = nil
        let ids = shots.map(\.id)
        let operation = UUID()
        batchID = operation
        collectionTask = Task { @MainActor in
            defer {
                if batchID == operation {
                    preparingAll = false
                    batchProgress = nil
                    batchID = nil
                    collectionTask = nil
                }
            }
            var images: [UIImage] = []
            for (index, id) in ids.enumerated() {
                guard !Task.isCancelled, batchID == operation, client.isConnected, client.capabilities.shareScreenshots else { return }
                batchProgress = "Preparing \(index + 1) of \(ids.count)…"
                // The host allows one full screenshot per second. Pace even the
                // first item so a recently opened preview cannot exhaust the limit.
                do { try await Task.sleep(nanoseconds: 1_100_000_000) }
                catch { return }
                guard !Task.isCancelled, batchID == operation, client.isConnected, client.capabilities.shareScreenshots else { return }
                let data: Data? = await withCheckedContinuation { continuation in
                    client.requestShot(id) { continuation.resume(returning: $0) }
                }
                guard !Task.isCancelled, batchID == operation, client.isConnected, client.capabilities.shareScreenshots else { return }
                if let data, let image = UIImage(data: data) { images.append(image) }
            }
            guard !images.isEmpty else {
                notice = "The shots are no longer available. Refresh the shelf and try again."
                return
            }
            if copy {
                let items: [[String: Any]] = images.compactMap { image in
                    guard let data = image.pngData() else { return nil }
                    return [UTType.png.identifier: data]
                }
                UIPasteboard.general.items = items
                notice = "Copied \(items.count) screenshots to this device."
            } else {
                shareImages = ShareImages(images: images)
            }
            if images.count < ids.count {
                notice = "Prepared \(images.count) of \(ids.count) shots. Some were removed from your Mac’s shelf."
            }
        }
    }
}

private struct ShotPreview: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ShareImages: Identifiable {
    let id = UUID()
    let images: [UIImage]
}

struct ShotDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State var image: UIImage
    var title = "Screenshot"
    var qualityNote = "Optimized JPEG copy · original stays on your Mac"
    @State private var showMarkup = false
    @State private var shareImages: ShareImages?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onDrag { NSItemProvider(object: image) }
                    .accessibilityLabel("\(title) preview. Drag to another app on iPad.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actionButtons }
                    VStack(spacing: 14) { actionButtons }
                }
                .font(.subheadline)
                Text("\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale)) pixels · drag to another app on iPad")
                    .font(.caption2).foregroundStyle(CompanionStyle.secondary)
                Text(qualityNote)
                    .font(.caption2).foregroundStyle(CompanionStyle.secondary)
            }
            .padding(22)
            .background(CompanionStyle.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showMarkup) {
                ShotMarkupView(image: image) { annotated in
                    image = annotated
                    copied = false
                    showMarkup = false
                }
            }
            .sheet(item: $shareImages) { images in CompanionShareSheet(items: images.images) }
        }
        .preferredColorScheme(.dark)
        .tint(CompanionStyle.yellow)
    }

    @ViewBuilder private var actionButtons: some View {
            Button { UIPasteboard.general.image = image; copied = true } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            Button("Annotate", systemImage: "pencil.tip.crop.circle") { showMarkup = true }
                .buttonStyle(.bordered)
            Button("Share", systemImage: "square.and.arrow.up") { shareImages = ShareImages(images: [image]) }
                .buttonStyle(.borderedProminent).foregroundStyle(.black)
    }
}

struct CompanionShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
