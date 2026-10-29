import Foundation
import UIKit

struct CharacterPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var tags: String
    var negative: String
}

struct ModelEntry: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isXL: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("TextEncoder2.mlmodelc").path)
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var characters: [CharacterPreset] = []
    @Published var models: [ModelEntry] = []
    @Published var history: [URL] = []

    nonisolated static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    nonisolated static let modelsDir = docs.appendingPathComponent("Models", isDirectory: true)
    nonisolated static let outputsDir = docs.appendingPathComponent("Outputs", isDirectory: true)
    nonisolated static let charsFile = docs.appendingPathComponent("characters.json")

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.modelsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.outputsDir, withIntermediateDirectories: true)
        loadCharacters()
        reloadModels()
        reloadHistory()
    }

    // MARK: キャラクター

    func loadCharacters() {
        guard let d = try? Data(contentsOf: Self.charsFile),
              let c = try? JSONDecoder().decode([CharacterPreset].self, from: d) else { return }
        characters = c
    }

    private func saveCharacters() {
        if let d = try? JSONEncoder().encode(characters) {
            try? d.write(to: Self.charsFile, options: .atomic)
        }
    }

    func upsert(_ c: CharacterPreset) {
        if let i = characters.firstIndex(where: { $0.id == c.id }) {
            characters[i] = c
        } else {
            characters.append(c)
        }
        characters.sort { $0.name < $1.name }
        saveCharacters()
    }

    func deleteCharacters(at offsets: IndexSet) {
        characters.remove(atOffsets: offsets)
        saveCharacters()
    }

    // MARK: モデル

    private static func isDir(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isModel(_ u: URL) -> Bool {
        let fm = FileManager.default
        let has = { (n: String) in fm.fileExists(atPath: u.appendingPathComponent(n).path) }
        return has("TextEncoder.mlmodelc") && (has("Unet.mlmodelc") || has("UnetChunk1.mlmodelc"))
    }

    private static func findModels(in dir: URL, depth: Int) -> [URL] {
        guard depth > 0 else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var out: [URL] = []
        for u in items where isDir(u) {
            if isModel(u) { out.append(u) } else { out += findModels(in: u, depth: depth - 1) }
        }
        return out
    }

    func reloadModels() {
        models = Self.findModels(in: Self.modelsDir, depth: 4)
            .map(ModelEntry.init)
            .sorted { $0.name < $1.name }
    }

    func importModel(from src: URL) async throws {
        let ok = src.startAccessingSecurityScopedResource()
        defer { if ok { src.stopAccessingSecurityScopedResource() } }
        let dst = Self.modelsDir.appendingPathComponent(src.lastPathComponent)
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }.value
        reloadModels()
    }

    // MARK: 履歴

    func reloadHistory() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.outputsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func date(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        history = files.filter { $0.pathExtension == "png" }.sorted { date($0) > date($1) }
    }

    func deleteImage(_ u: URL) {
        try? FileManager.default.removeItem(at: u)
        try? FileManager.default.removeItem(at: u.deletingPathExtension().appendingPathExtension("json"))
        reloadHistory()
    }

    nonisolated static func saveOutput(_ cg: CGImage, seed: UInt32, meta: [String: Any]) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        let url = outputsDir.appendingPathComponent("\(f.string(from: Date()))_\(seed).png")
        guard let data = UIImage(cgImage: cg).pngData() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        let json = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: url.deletingPathExtension().appendingPathExtension("json"))
        return url
    }
}
