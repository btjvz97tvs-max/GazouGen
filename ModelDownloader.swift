import Foundation
import UIKit

struct ReleaseInfo: Decodable, Identifiable {
    let id: Int
    let tag_name: String
    let name: String?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let size: Int
        let browser_download_url: URL
    }

    var totalSize: Int { assets.reduce(0) { $0 + $1.size } }
    var title: String { (name?.isEmpty == false ? name! : tag_name) }
}

struct ModelManifest: Decodable {
    let name: String
    let files: [File]

    struct File: Decodable {
        let path: String
        let size: Int
        let parts: [String]
    }
}

/// 1ファイルを進捗付きでダウンロードする
final class PartDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var finishedFile: URL?
    private var finishError: Error?
    private let onProgress: (Int64) -> Void
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(onProgress: @escaping (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func download(_ url: URL) async throws -> URL {
        finishedFile = nil
        finishError = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                continuation = c
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.getAllTasks { $0.forEach { $0.cancel() } }
        }
    }

    func invalidate() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(bytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finishError = URLError(.badServerResponse)
            return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            finishedFile = tmp
        } catch {
            finishError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation
        continuation = nil
        if let e = error ?? finishError {
            c?.resume(throwing: e)
        } else if let f = finishedFile {
            c?.resume(returning: f)
        } else {
            c?.resume(throwing: URLError(.unknown))
        }
    }
}

@MainActor
final class ModelDownloader: ObservableObject {
    @Published var releases: [ReleaseInfo] = []
    @Published var isLoading = false
    @Published var isDownloading = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?
    private var doneBytes: Int64 = 0
    private var totalBytes: Int64 = 0

    nonisolated static let workDir = AppStore.docs.appendingPathComponent("Downloading", isDirectory: true)

    func fetchReleases(repo: String) async {
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://api.github.com/repos/\(r)/releases?per_page=50") else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                errorMessage = "取得できませんでした（リポジトリ名と、公開設定になっているかを確認してください）"
                return
            }
            let all = try JSONDecoder().decode([ReleaseInfo].self, from: data)
            releases = all.filter { $0.tag_name.hasPrefix("model-") && $0.assets.contains { $0.name == "manifest.json" } }
            if releases.isEmpty { errorMessage = "変換済みのモデルがまだありません" }
        } catch {
            errorMessage = "取得エラー：\(error.localizedDescription)"
        }
    }

    func cancel() {
        task?.cancel()
        status = "中止しています…"
    }

    func download(_ release: ReleaseInfo, store: AppStore) {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        errorMessage = nil
        status = "準備中…"
        UIApplication.shared.isIdleTimerDisabled = true

        task = Task {
            do {
                try await run(release, store: store)
                status = "完了しました"
            } catch is CancellationError {
                status = "中止しました"
            } catch let e as URLError where e.code == .cancelled {
                status = "中止しました"
            } catch {
                errorMessage = "ダウンロードエラー：\(error.localizedDescription)"
                status = ""
            }
            isDownloading = false
            UIApplication.shared.isIdleTimerDisabled = false
            try? FileManager.default.removeItem(at: Self.workDir)
        }
    }

    private func run(_ release: ReleaseInfo, store: AppStore) async throws {
        let fm = FileManager.default
        let assets = Dictionary(uniqueKeysWithValues: release.assets.map { ($0.name, $0) })
        guard let mAsset = assets["manifest.json"] else { throw URLError(.fileDoesNotExist) }
        let (mData, _) = try await URLSession.shared.data(from: mAsset.browser_download_url)
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: mData)

        let total = Int64(manifest.files.reduce(0) { $0 + $1.size })
        totalBytes = total
        doneBytes = 0

        // 空き容量チェック（組み立て中は一時的に1パート分多く必要）
        if let free = try? AppStore.docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           free < total + 2_100_000_000 {
            let need = Double(total + 2_100_000_000) / 1_000_000_000
            throw NSError(domain: "GazouGen", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(format: "空き容量が足りません（約%.1fGB必要）", need)])
        }

        try? fm.removeItem(at: Self.workDir)
        let work = Self.workDir.appendingPathComponent(manifest.name, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let downloader = PartDownloader { [weak self] bytes in
            Task { @MainActor in
                guard let self else { return }
                self.doneBytes += bytes
                let t = self.totalBytes
                self.progress = t > 0 ? Double(self.doneBytes) / Double(t) : 0
                self.status = String(format: "ダウンロード中 %.2f / %.2f GB",
                                     Double(self.doneBytes) / 1e9, Double(t) / 1e9)
            }
        }
        defer { downloader.invalidate() }

        for file in manifest.files {
            try Task.checkCancellation()
            let dest = work.appendingPathComponent(file.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: dest.path, contents: nil)
            let out = try FileHandle(forWritingTo: dest)
            defer { try? out.close() }

            for partName in file.parts {
                try Task.checkCancellation()
                guard let asset = assets[partName] else { throw URLError(.fileDoesNotExist) }
                let tmp = try await downloader.download(asset.browser_download_url)
                try await Task.detached(priority: .utility) {
                    let input = try FileHandle(forReadingFrom: tmp)
                    defer { try? input.close() }
                    while let chunk = try input.read(upToCount: 16 * 1024 * 1024), !chunk.isEmpty {
                        try out.write(contentsOf: chunk)
                    }
                    try FileManager.default.removeItem(at: tmp)
                }.value
            }
        }

        status = "仕上げ中…"
        let final = AppStore.modelsDir.appendingPathComponent(manifest.name, isDirectory: true)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: work, to: final)
        store.reloadModels()
        progress = 1
    }
}
