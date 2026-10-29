import SwiftUI
import UniformTypeIdentifiers

// MARK: 履歴

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var viewing: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.history.isEmpty {
                    ContentUnavailableView("まだ画像がありません", systemImage: "photo")
                        .padding(.top, 80)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)], spacing: 4) {
                    ForEach(store.history) { u in
                        Thumb(url: u).onTapGesture { viewing = u }
                    }
                }
                .padding(4)
            }
            .navigationTitle("履歴")
            .refreshable { store.reloadHistory() }
            .onAppear { store.reloadHistory() }
            .sheet(item: $viewing) { u in
                ImageDetailView(url: u).environmentObject(store)
            }
        }
    }
}

// MARK: キャラクター

struct CharactersView: View {
    @EnvironmentObject var store: AppStore
    @State private var editing: CharacterPreset?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.characters) { c in
                    Button {
                        editing = c
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).foregroundStyle(.primary)
                            Text(c.tags).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .onDelete { store.deleteCharacters(at: $0) }
            }
            .overlay {
                if store.characters.isEmpty {
                    ContentUnavailableView("キャラがいません",
                                           systemImage: "person.crop.square",
                                           description: Text("見た目のタグを保存しておくと、毎回同じキャラを呼び出せます"))
                }
            }
            .navigationTitle("キャラクター")
            .toolbar {
                Button {
                    editing = CharacterPreset(name: "", tags: "", negative: "")
                } label: {
                    Image(systemName: "plus")
                }
            }
            .sheet(item: $editing) { c in
                CharacterEditor(preset: c).environmentObject(store)
            }
        }
    }
}

struct CharacterEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var preset: CharacterPreset
    @State private var building = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("キャラ名", text: $preset.name)
                Section {
                    Button {
                        building = true
                    } label: {
                        Label("選ぶだけでかんたん作成", systemImage: "sparkles")
                    }
                }
                Section("見た目タグ") {
                    TextField("例: 1girl, long hair, silver hair, red eyes", text: $preset.tags, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("このキャラ用ネガティブ") {
                    TextField("任意", text: $preset.negative, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .sheet(isPresented: $building) {
                CharacterBuilder { preset.tags = $0 }
            }
            .navigationTitle(preset.name.isEmpty ? "新しいキャラ" : preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.upsert(preset)
                        dismiss()
                    }
                    .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: モデル

struct ModelsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var gen: Generator
    @State private var importing = false
    @State private var copying = false
    @State private var errorText: String?
    @EnvironmentObject var dl: ModelDownloader
    @AppStorage("repo") private var repo = "btjvz97tvs-max/GazouGen"
    @State private var confirm: ReleaseInfo?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("ユーザー名/リポジトリ名", text: $repo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await dl.fetchReleases(repo: repo) }
                    } label: {
                        Label(dl.isLoading ? "取得中…" : "変換済みモデルを探す", systemImage: "arrow.down.circle")
                    }
                    .disabled(dl.isLoading || dl.isDownloading)
                    ForEach(dl.releases) { r in
                        Button {
                            confirm = r
                        } label: {
                            HStack {
                                Text(r.title).foregroundStyle(.primary)
                                Spacer()
                                if store.models.contains(where: { $0.name == r.modelName }) {
                                    Label("入手済み", systemImage: "checkmark.circle.fill")
                                        .font(.caption).foregroundStyle(.green)
                                } else {
                                    Text("NEW").font(.caption2.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.red, in: Capsule())
                                        .foregroundStyle(.white)
                                    Text(String(format: "%.1f GB", Double(r.totalSize) / 1e9))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(dl.isDownloading)
                    }
                    if dl.isDownloading {
                        ProgressView(value: dl.progress) { Text(dl.status).font(.footnote) }
                        Button("中止", role: .destructive) { dl.cancel() }
                    } else if !dl.status.isEmpty {
                        Text(dl.status).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let e = dl.errorMessage {
                        Text(e).foregroundStyle(.red).font(.footnote)
                    }
                } header: {
                    Text("GitHubからダウンロード")
                } footer: {
                    Text("Wi-Fi接続で、画面を開いたまま待ってください（数GBあります）。")
                }
                Section("インストール済み") {
                    if store.models.isEmpty {
                        Text("まだモデルがありません").foregroundStyle(.secondary)
                    }
                    ForEach(store.models) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name)
                            Text(m.isXL ? "SDXL" : "SD 1.5 / 2.x").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        guard !gen.isRunning else { return }
                        gen.unload()
                        for i in idx { try? FileManager.default.removeItem(at: store.models[i].url) }
                        store.reloadModels()
                    }
                }
                Section {
                    Button {
                        importing = true
                    } label: {
                        Label(copying ? "コピー中…" : "フォルダから追加", systemImage: "folder.badge.plus")
                    }
                    .disabled(copying)
                    if let errorText {
                        Text(errorText).foregroundStyle(.red).font(.footnote)
                    }
                } footer: {
                    Text("Core ML 形式（.mlmodelc が入ったフォルダ）のモデルが使えます。「ファイル」アプリで「このiPhone内 > 画像生成 > Models」に直接入れてもOKです。")
                }
            }
            .navigationTitle("モデル")
            .confirmationDialog("このモデルをダウンロードしますか？",
                                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible,
                                presenting: confirm) { r in
                Button("ダウンロード（\(String(format: "%.1f GB", Double(r.totalSize) / 1e9))）") {
                    gen.unload()
                    dl.download(r, store: store)
                }
            }
            .refreshable { store.reloadModels() }
            .onAppear { store.reloadModels() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                copying = true
                errorText = nil
                Task {
                    do { try await store.importModel(from: url) }
                    catch { errorText = error.localizedDescription }
                    copying = false
                }
            }
        }
    }
}
