import SwiftUI
import StableDiffusion

struct GenerateView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var gen: Generator

    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("charID") private var charID = ""
    @AppStorage("prompt") private var prompt = ""
    @AppStorage("negative") private var negative = ""
    @AppStorage("r18") private var r18 = false
    @AppStorage("steps") private var steps = 30
    @AppStorage("cfg") private var cfg = 6.0
    @AppStorage("seedText") private var seedText = "-1"
    @AppStorage("count") private var count = 1
    @AppStorage("scheduler") private var schedulerKey = "dpmk"

    @State private var alertMessage: String?
    @State private var viewing: URL?

    static let quality = "masterpiece, best quality, amazing quality, very aesthetic, absurdres"
    static let negBase = "lowres, bad anatomy, bad hands, missing fingers, extra digits, fewer digits, worst quality, low quality, jpeg artifacts, blurry, watermark, signature, text"
    static let negSFW = "nsfw, nude"

    var body: some View {
        NavigationStack {
            Form {
                Section("モデルとキャラ") {
                    if store.models.isEmpty {
                        Text("モデルがありません。「モデル」タブから追加してください")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("モデル", selection: $modelPath) {
                            ForEach(store.models) { m in
                                Text(m.name + (m.isXL ? "（XL）" : "")).tag(m.id)
                            }
                        }
                    }
                    Picker("キャラ", selection: $charID) {
                        Text("なし").tag("")
                        ForEach(store.characters) { c in Text(c.name).tag(c.id.uuidString) }
                    }
                }

                Section("プロンプト") {
                    TextField("ポーズ・服・背景など（英語タグ推奨）", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("追加のネガティブ", text: $negative, axis: .vertical)
                        .lineLimit(1...4)
                    Toggle("R18 モード", isOn: $r18)
                }

                Section("設定") {
                    Stepper("ステップ数: \(steps)", value: $steps, in: 5...60)
                    VStack(alignment: .leading) {
                        Text("CFG: \(cfg, specifier: "%.1f")")
                        Slider(value: $cfg, in: 1...12, step: 0.5)
                    }
                    Picker("スケジューラ", selection: $schedulerKey) {
                        Text("DPM++ Karras（高画質）").tag("dpmk")
                        Text("DPM++").tag("dpm")
                        Text("PNDM").tag("pndm")
                    }
                    HStack {
                        Text("シード")
                        TextField("-1でランダム", text: $seedText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    Stepper("枚数: \(count)", value: $count, in: 1...8)
                }

                Section {
                    if gen.isRunning {
                        ProgressView(value: gen.progress) {
                            Text(gen.status).font(.footnote)
                        }
                        Button("中止", role: .destructive) { gen.cancel() }
                    } else {
                        Button {
                            startGeneration()
                        } label: {
                            Label("生成", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(store.models.isEmpty)
                    }
                    if let e = gen.errorMessage {
                        Text(e).foregroundStyle(.red).font(.footnote)
                    }
                }

                if !gen.results.isEmpty {
                    Section("結果") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 8) {
                            ForEach(gen.results) { u in
                                Thumb(url: u).onTapGesture { viewing = u }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("生成")
            .scrollDismissesKeyboard(.interactively)
            .alert("生成できません",
                   isPresented: Binding(get: { alertMessage != nil },
                                        set: { if !$0 { alertMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(alertMessage ?? "")
            }
            .sheet(item: $viewing) { u in
                ImageDetailView(url: u).environmentObject(store)
            }
            .onAppear {
                if !store.models.contains(where: { $0.id == modelPath }) {
                    modelPath = store.models.first?.id ?? ""
                }
            }
        }
    }

    private func startGeneration() {
        guard let model = store.models.first(where: { $0.id == modelPath }) ?? store.models.first else { return }
        let char = store.characters.first { $0.id.uuidString == charID }

        var pos = [Self.quality]
        if let t = char?.tags, !t.isEmpty { pos.append(t) }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { pos.append(p) }
        let positive = pos.joined(separator: ", ")

        var neg = [Self.negBase]
        if !r18 { neg.append(Self.negSFW) }
        if let n = char?.negative, !n.isEmpty { neg.append(n) }
        let n2 = negative.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n2.isEmpty { neg.append(n2) }

        if r18, let reason = AgeCheck.check(positive) {
            alertMessage = "R18 モードでは生成できません：\(reason)"
            return
        }

        let seed: UInt32
        if let v = Int64(seedText.trimmingCharacters(in: .whitespaces)), v >= 0 {
            seed = UInt32(truncatingIfNeeded: v)
        } else {
            seed = UInt32.random(in: 0...UInt32.max)
        }

        let req = GenRequest(
            prompt: positive,
            negative: neg.joined(separator: ", "),
            steps: steps,
            cfg: Float(cfg),
            seed: seed,
            count: count,
            scheduler: schedulerKey == "pndm" ? .pndmScheduler : .dpmSolverMultistepScheduler,
            karras: schedulerKey == "dpmk",
            r18: r18,
            modelName: model.name
        )
        gen.start(req, model: model, store: store)
    }
}

struct Thumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .task(id: url) {
            let u = url
            image = await Task.detached {
                guard let img = UIImage(contentsOfFile: u.path) else { return nil }
                let s = 320 / max(img.size.width, img.size.height)
                return img.preparingThumbnail(of: CGSize(width: img.size.width * s, height: img.size.height * s))
            }.value
        }
    }
}

struct ImageDetailView: View {
    let url: URL
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var meta = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                Text(meta)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    ShareLink(item: url)
                    Spacer()
                    Button {
                        if let image {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                            saved = true
                        }
                    } label: {
                        Label(saved ? "保存済み" : "写真に保存",
                              systemImage: saved ? "checkmark" : "square.and.arrow.down")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        store.deleteImage(url)
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .task {
                image = UIImage(contentsOfFile: url.path)
                let j = url.deletingPathExtension().appendingPathExtension("json")
                if let d = try? Data(contentsOf: j), let s = String(data: d, encoding: .utf8) {
                    meta = s
                }
            }
        }
    }
}
