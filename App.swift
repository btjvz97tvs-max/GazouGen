import SwiftUI

@main
struct GazouGenApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var generator = Generator()
    @StateObject private var downloader = ModelDownloader()
    @AppStorage("repo") private var repo = "btjvz97tvs-max/GazouGen"
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var showNew = false

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                GenerateView()
                    .tabItem { Label("生成", systemImage: "wand.and.stars") }
                    .tag(0)
                HistoryView()
                    .tabItem { Label("履歴", systemImage: "photo.on.rectangle") }
                    .tag(1)
                CharactersView()
                    .tabItem { Label("キャラ", systemImage: "person.crop.square") }
                    .tag(2)
                ModelsView()
                    .tabItem { Label("モデル", systemImage: "cpu") }
                    .badge(notInstalledCount)
                    .tag(3)
            }
            .environmentObject(store)
            .environmentObject(generator)
            .environmentObject(downloader)
            // 起動時と、アプリに戻ってきたときに新しいモデルを確認
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { Task { await checkForNewModels() } }
            }
            .alert("新しいモデルがあります", isPresented: $showNew) {
                Button("モデルタブを開く") {
                    downloader.markSeen()
                    tab = 3
                }
                Button("あとで", role: .cancel) { downloader.markSeen() }
            } message: {
                Text(downloader.newModels.map(\.modelName).joined(separator: "\n"))
            }
        }
    }

    /// GitHubにあって、まだ入れていないモデルの数（タブのバッジ）
    private var notInstalledCount: Int {
        let installed = Set(store.models.map(\.name))
        return downloader.releases.filter { !installed.contains($0.modelName) }.count
    }

    @MainActor
    private func checkForNewModels() async {
        guard !showNew, !generator.isRunning else { return }
        store.reloadModels()
        await downloader.checkForNew(repo: repo, installed: store.models.map(\.name))
        if !downloader.newModels.isEmpty { showNew = true }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
