import SwiftUI
import UIKit

struct CompanionClipboardView: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var shelf: CompanionShelf
    @State private var draft = ""
    @State private var search = ""
    @State private var filter: ClipFilter = .all
    @State private var confirmClear = false
    @State private var copiedText: String?
    @State private var imagePreview: ClipboardImagePreview?
    @State private var imageShare: ClipboardImageShare?
    @State private var downloadingImageID: String?
    @State private var imageRequestGeneration = UUID()
    @State private var imageNotice: String?

    private enum ClipFilter: String, CaseIterable {
        case all = "All", links = "Links", code = "Code", colors = "Colors"
    }

    private var remoteClips: [BridgeClip] {
        guard client.capabilities.shareClipboard else { return [] }
        return (client.snapshot?.clips ?? []).filter { clip in
            (clip.kind != "image" || client.capabilities.shareClipboardImages) && matches(clip.text, kind: clip.kind)
        }
    }

    private var localItems: [LocalShelfItem] {
        shelf.items.filter { matches($0.text, kind: "text") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Good ideas travel light.").font(.title2.weight(.bold))
                    Text("A place for the text, links, and snippets you want to keep.")
                        .font(.subheadline).foregroundStyle(CompanionStyle.secondary)
                }
                composer
                if client.isConnected && client.selectedWindowID == nil {
                    Text("Choose a window in Windows before pasting to your Mac. Copy to Mac works without a selected window.")
                        .font(.caption).foregroundStyle(CompanionStyle.secondary)
                }
                if let storageError = shelf.storageError {
                    PermissionNote(title: "Shelf storage", detail: storageError)
                }
                if let imageNotice {
                    Text(imageNotice).font(.caption).foregroundStyle(CompanionStyle.cyan)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(CompanionStyle.secondary)
                    TextField("Search your shelves", text: $search)
                        .font(.subheadline).autocorrectionDisabled()
                        .accessibilityIdentifier("shelfSearch")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(14).background(CompanionStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                Picker("Filter clipboard items", selection: $filter) {
                    ForEach(ClipFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                ShelfSectionTitle(title: "From your Mac", detail: "\(remoteClips.count) ITEMS")
                if remoteClips.isEmpty {
                    ShelfEmptyState(symbol: "arrow.down.doc", title: client.isConnected ? "Your Mac shelf is quiet" : "Your Mac shelf lives here", detail: client.isConnected ? "Enable clipboard sharing in Show Bar → Companion devices on your Mac. New copied text appears while connected." : "Connect your Mac to bring its shared clipboard history here.")
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(remoteClips) { clip in
                            clipCard(text: clip.text, kind: clip.kind, date: clip.date, localItem: nil, remoteClip: clip)
                        }
                    }
                }
                HStack {
                    ShelfSectionTitle(title: "On this device", detail: "\(localItems.count) ITEMS")
                    if !shelf.items.isEmpty {
                        Button(role: .destructive) { confirmClear = true } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Clear local shelf")
                    }
                }
                if localItems.isEmpty {
                    ShelfEmptyState(symbol: "tray", title: shelf.items.isEmpty ? "Keep something useful" : "No matching items", detail: shelf.items.isEmpty ? "Paste explicitly using the button above, or write a note. Your clipboard is never read automatically." : "Try a different search or filter.")
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(localItems) { item in
                            clipCard(text: item.text, kind: "text", date: item.date, localItem: item)
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onDisappear {
            imageRequestGeneration = UUID()
            downloadingImageID = nil
            client.cancelAssetRequests()
        }
        .sheet(item: $imagePreview) { preview in
            ShotDetailView(image: preview.image, title: "Clipboard image", qualityNote: "PNG copy from your Mac clipboard. The source stays on your Mac.")
        }
        .sheet(item: $imageShare) { share in
            CompanionShareSheet(items: [share.image])
        }
        .confirmationDialog("Clear this device’s shelf?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear local shelf", role: .destructive) { shelf.clear() }
        } message: {
            Text("Saved text on this device will be removed. Your Mac’s clipboard history stays on your Mac.")
        }
    }

    private var composer: some View {
        ShelfCard {
            VStack(alignment: .leading, spacing: 13) {
                ShelfSectionTitle(title: "Make room for an idea", detail: "LOCAL SHELF")
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft)
                        .font(.system(.subheadline, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 95, maxHeight: 180)
                        .padding(6)
                        .accessibilityLabel("New shelf note")
                        .accessibilityIdentifier("shelfDraft")
                    if draft.isEmpty {
                        Text("A link, a snippet, a thought…")
                            .font(.subheadline).foregroundStyle(CompanionStyle.secondary)
                            .padding(14).allowsHitTesting(false)
                    }
                }
                .background(CompanionStyle.background, in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    PasteButton(payloadType: String.self) { values in
                        for value in values where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            shelf.add(value)
                        }
                    }
                    Spacer()
                    Button("Keep note", systemImage: "plus") {
                        if shelf.add(draft) { draft = "" }
                    }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func clipCard(text: String, kind: String, date: Date, localItem: LocalShelfItem?, remoteClip: BridgeClip? = nil) -> some View {
        ShelfCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    HStack(spacing: 6) {
                        if isColor(text) {
                            Circle().fill(color(text)).frame(width: 9, height: 9)
                        }
                        Text(label(text, kind: kind))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                            .foregroundStyle(CompanionStyle.cyan)
                    }
                    Spacer()
                    Text(date, style: .relative).font(.caption2).foregroundStyle(CompanionStyle.secondary)
                    if let localItem {
                        Button(role: .destructive) { shelf.remove(localItem) } label: { Image(systemName: "xmark") }
                            .font(.caption).accessibilityLabel("Remove this shelf item")
                    }
                }
                if kind == "image", let clip = remoteClip {
                    clipboardImage(clip)
                } else {
                    Text(text)
                        .font(isCode(text) || isColor(text) ? .system(.subheadline, design: .monospaced) : .subheadline)
                        .lineLimit(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if remoteClip?.isTruncated == true {
                        Text("This is a shortened preview. Copy and Paste are unavailable for this item; use the full item on your Mac.")
                            .font(.caption).foregroundStyle(CompanionStyle.yellow)
                    }
                    ViewThatFits(in: .horizontal) {
                        clipActions(text)
                        VStack(alignment: .leading, spacing: 12) {
                            copyButton(text)
                            remoteActions(text)
                        }
                    }
                    .disabled(remoteClip?.isTruncated == true)
                }
            }
        }
    }

    private func clipActions(_ text: String) -> some View {
        HStack(spacing: 14) {
            copyButton(text)
            Spacer(minLength: 0)
            remoteActions(text)
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            copiedText = text
        } label: {
            Label(copiedText == text ? "Copied" : "Copy", systemImage: copiedText == text ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
        }
        .accessibilityLabel(copiedText == text ? "Copied to this device" : "Copy to this device")
    }

    private func remoteActions(_ text: String) -> some View {
        HStack(spacing: 13) {
            Button("Copy to Mac") { client.sendText(text, paste: false) }
                .font(.caption.weight(.medium))
                .foregroundStyle(CompanionStyle.secondary)
                .disabled(!client.capabilities.allowCopyToMac)
            Button("Paste to Mac", systemImage: "arrow.up.right") { client.sendText(text, paste: true) }
                .font(.caption.weight(.semibold))
                .disabled(!client.capabilities.allowPasteToMac || client.snapshot?.permissions.accessibility != true || client.selectedWindowID == nil)
        }
        .disabled(!client.isConnected || client.isDemo)
    }

    @ViewBuilder private func clipboardImage(_ clip: BridgeClip) -> some View {
        if let data = clip.thumbnail, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Mac clipboard image preview")
        } else {
            Label("Image on your Mac", systemImage: "photo")
                .foregroundStyle(CompanionStyle.secondary)
        }
        if !clip.text.isEmpty && clip.text != "Image" {
            Text(clip.text).font(.caption).foregroundStyle(CompanionStyle.secondary).lineLimit(2)
        }
        if downloadingImageID == clip.id {
            HStack(spacing: 9) {
                ProgressView().tint(CompanionStyle.cyan)
                Text("Getting image from your Mac…").font(.caption)
            }
            .accessibilityElement(children: .combine)
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { imageActions(clip) }
            VStack(alignment: .leading, spacing: 14) { imageActions(clip) }
        }
        .font(.caption.weight(.semibold))
        .disabled(!client.isConnected || client.isDemo || !client.capabilities.shareClipboard || !client.capabilities.shareClipboardImages || downloadingImageID != nil)
    }

    @ViewBuilder private func imageActions(_ clip: BridgeClip) -> some View {
        Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { fetchImage(clip, action: .open) }
            .accessibilityLabel("Open Mac clipboard image")
        Button("Copy", systemImage: "doc.on.doc") { fetchImage(clip, action: .copy) }
            .accessibilityLabel("Copy Mac clipboard image to this device")
        Button("Share", systemImage: "square.and.arrow.up") { fetchImage(clip, action: .share) }
            .accessibilityLabel("Share Mac clipboard image")
    }

    private func fetchImage(_ clip: BridgeClip, action: ClipboardImageAction) {
        guard downloadingImageID == nil, client.isConnected, !client.isDemo,
              client.capabilities.shareClipboard, client.capabilities.shareClipboardImages else { return }
        downloadingImageID = clip.id
        imageNotice = nil
        let generation = UUID()
        imageRequestGeneration = generation
        client.requestClipImage(clip.id) { data in
            guard imageRequestGeneration == generation else { return }
            downloadingImageID = nil
            guard client.isConnected, client.capabilities.shareClipboard, client.capabilities.shareClipboardImages else { return }
            guard let data, let image = UIImage(data: data) else {
                imageNotice = "The image could not be downloaded. Check that image sharing is still enabled on your Mac, then refresh."
                return
            }
            switch action {
            case .open: imagePreview = ClipboardImagePreview(image: image)
            case .copy:
                UIPasteboard.general.image = image
                imageNotice = "Copied image to this device."
            case .share: imageShare = ClipboardImageShare(image: image)
            }
        }
    }

    private enum ClipboardImageAction { case open, copy, share }

    private struct ClipboardImagePreview: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private struct ClipboardImageShare: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private func matches(_ text: String, kind: String) -> Bool {
        guard search.isEmpty || text.localizedCaseInsensitiveContains(search) else { return false }
        switch filter {
        case .all: return true
        case .links: return isLink(text)
        case .code: return isCode(text) && kind != "image"
        case .colors: return isColor(text)
        }
    }

    private func label(_ text: String, kind: String) -> String {
        if kind == "image" { return "IMAGE" }
        if isColor(text) { return "COLOR" }
        if isLink(text) { return "LINK" }
        if isCode(text) { return "SNIPPET" }
        return "TEXT"
    }

    private func isLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    private func isCode(_ text: String) -> Bool {
        text.contains("\n") && ["{", "}", "func ", "let ", "const ", "def ", "import "].contains { text.contains($0) }
    }

    private func isColor(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }

    private func color(_ text: String) -> Color {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst()
        guard let value = UInt32(raw, radix: 16) else { return .clear }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
