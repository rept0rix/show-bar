import AppKit
import SwiftUI

/// Owner view of public download counts. GitHub counts each file download.
/// It does not name the person, and Show Bar does not report who is running it.
enum AdminBoard {
    static func load() async throws -> [ReleaseFile] {
        let summaries = try await get([ReleaseSummary].self, path: "releases?per_page=20")
        var files: [ReleaseFile] = []
        for summary in summaries {
            let release = try await get(ReleaseDetail.self, path: "releases/\(summary.id)")
            if release.assets.isEmpty {
                files.append(ReleaseFile(id: "\(release.tagName)-none", version: release.tagName, file: "No file", downloads: 0))
            } else {
                for asset in release.assets {
                    files.append(ReleaseFile(
                        id: "\(release.tagName)-\(asset.name)",
                        version: release.tagName,
                        file: asset.name,
                        downloads: asset.downloadCount
                    ))
                }
            }
        }
        return files
    }

    private static func get<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        guard let url = URL(string: "https://api.github.com/repos/rept0rix/show-bar/\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("ShowBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

struct ReleaseFile: Identifiable {
    let id: String
    let version: String
    let file: String
    let downloads: Int
}

private struct ReleaseSummary: Decodable {
    let id: Int
    let tagName: String

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
    }
}

private struct ReleaseDetail: Decodable {
    let tagName: String
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct ReleaseAsset: Decodable {
    let name: String
    let downloadCount: Int

    enum CodingKeys: String, CodingKey {
        case name
        case downloadCount = "download_count"
    }
}

final class AdminModel: ObservableObject {
    @Published var files: [ReleaseFile] = []
    @Published var totalDownloads = 0
    @Published var message = "Loading downloads…"
    @Published var failed = false

    var thisMacVersion: String { ShowBarSupport.version }

    func reload() {
        message = "Loading downloads…"
        failed = false
        Task {
            do {
                let files = try await AdminBoard.load()
                let total = files.reduce(0) { $0 + $1.downloads }
                await MainActor.run {
                    self.files = files
                    self.totalDownloads = total
                    self.message = ""
                    self.failed = false
                }
            } catch {
                await MainActor.run {
                    self.failed = true
                    self.message = "GitHub did not answer. Try again."
                }
            }
        }
    }
}

struct AdminView: View {
    @ObservedObject var model: AdminModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Admin")
                    .font(.title2.weight(.semibold))
                Text("Downloads come from the public GitHub release. A download is a file fetch, so one person can count more than once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloaded")
                        .font(.headline)
                    Text("\(model.totalDownloads)")
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                    if model.files.isEmpty {
                        Text(model.message)
                            .foregroundStyle(model.failed ? Color.orange : Color.secondary)
                    } else {
                        ForEach(model.files) { file in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.file)
                                    Text(file.version)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(file.downloads)")
                                    .font(.title3.weight(.semibold))
                                    .monospacedDigit()
                            }
                        }
                    }
                    Button("Refresh") { model.reload() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Using it")
                        .font(.headline)
                    Text("Unknown")
                        .font(.title3.weight(.semibold))
                    Text("Show Bar keeps no list of people. This window only knows the Mac it is open on: version \(model.thisMacVersion).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Bought")
                        .font(.headline)
                    Text("0")
                        .font(.title3.weight(.semibold))
                    Text("Show Bar is free. The store page is not connected, so there is nothing to buy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.reload() }
    }
}
