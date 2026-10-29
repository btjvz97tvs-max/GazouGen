import SwiftUI

@main
struct GazouGenApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var generator = Generator()

    var body: some Scene {
        WindowGroup {
            TabView {
                GenerateView()
                    .tabItem { Label("生成", systemImage: "wand.and.stars") }
                HistoryView()
                    .tabItem { Label("履歴", systemImage: "photo.on.rectangle") }
                CharactersView()
                    .tabItem { Label("キャラ", systemImage: "person.crop.square") }
                ModelsView()
                    .tabItem { Label("モデル", systemImage: "cpu") }
            }
            .environmentObject(store)
            .environmentObject(generator)
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
