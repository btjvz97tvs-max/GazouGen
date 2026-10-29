import Foundation
import CoreML
import CoreGraphics
import StableDiffusion

struct GenRequest {
    var prompt: String
    var negative: String
    var steps: Int
    var cfg: Float
    var seed: UInt32
    var count: Int
    var scheduler: StableDiffusionScheduler
    var r18: Bool
    var modelName: String
}

/// Core ML パイプラインを保持して生成を行う（バックグラウンドで使う）
final class Engine: @unchecked Sendable {
    private var pipeline: (any StableDiffusionPipelineProtocol)?
    private var loadedPath: String?
    private var isXL = false
    private let lock = NSLock()
    private var _cancelled = false

    var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }

    func load(_ model: URL, xl: Bool) throws {
        if loadedPath == model.path, pipeline != nil { return }
        unload()
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let p: any StableDiffusionPipelineProtocol
        if xl {
            p = try StableDiffusionXLPipeline(resourcesAt: model, configuration: config, reduceMemory: true)
        } else {
            p = try StableDiffusionPipeline(resourcesAt: model, controlNet: [], configuration: config,
                                            disableSafety: false, reduceMemory: true)
        }
        try p.loadResources()
        pipeline = p
        loadedPath = model.path
        isXL = xl
    }

    func unload() {
        pipeline?.unloadResources()
        pipeline = nil
        loadedPath = nil
    }

    func generate(_ r: GenRequest, seed: UInt32, progress: @escaping (Int, Int) -> Void) throws -> CGImage? {
        guard let p = pipeline else { return nil }
        var c = PipelineConfiguration(prompt: r.prompt)
        c.negativePrompt = r.negative
        c.stepCount = r.steps
        c.guidanceScale = r.cfg
        c.seed = seed
        c.imageCount = 1
        c.schedulerType = r.scheduler
        c.disableSafety = r.r18
        if isXL {
            c.encoderScaleFactor = 0.13025
            c.decoderScaleFactor = 0.13025
        }
        let images = try p.generateImages(configuration: c) { prog in
            progress(prog.step, prog.stepCount)
            return !self.cancelled
        }
        return images.compactMap { $0 }.first
    }
}

@MainActor
final class Generator: ObservableObject {
    @Published var isRunning = false
    @Published var status = ""
    @Published var progress: Double = 0
    @Published var results: [URL] = []
    @Published var errorMessage: String?

    private let engine = Engine()

    func cancel() {
        engine.cancelled = true
        status = "中止しています…"
    }

    func unload() {
        if !isRunning { engine.unload() }
    }

    func start(_ r: GenRequest, model: ModelEntry, store: AppStore) {
        guard !isRunning else { return }
        isRunning = true
        results = []
        errorMessage = nil
        progress = 0
        engine.cancelled = false
        status = "モデルを読み込み中…（初回は数分かかります）"

        let engine = self.engine
        let url = model.url
        let xl = model.isXL

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try engine.load(url, xl: xl)
                for i in 0..<r.count {
                    if engine.cancelled { break }
                    let seed = r.seed &+ UInt32(i)
                    let img = try engine.generate(r, seed: seed) { step, total in
                        Task { @MainActor in
                            self?.status = "\(i + 1)/\(r.count)枚目  ステップ \(step)/\(total)"
                            self?.progress = (Double(i) + Double(step) / Double(max(total, 1))) / Double(r.count)
                        }
                    }
                    if engine.cancelled { break }
                    guard let img else {
                        await MainActor.run {
                            self?.errorMessage = "画像が出力されませんでした（モデル内蔵の安全フィルタで除外された可能性があります）"
                        }
                        continue
                    }
                    let meta: [String: Any] = [
                        "positive": r.prompt, "negative": r.negative, "seed": Int(seed),
                        "steps": r.steps, "cfg": Double(r.cfg), "model": r.modelName, "r18": r.r18,
                    ]
                    let saved = try AppStore.saveOutput(img, seed: seed, meta: meta)
                    await MainActor.run {
                        self?.results.append(saved)
                        store.reloadHistory()
                    }
                }
            } catch {
                await MainActor.run { self?.errorMessage = "エラー：\(error.localizedDescription)" }
            }
            await MainActor.run {
                self?.isRunning = false
                self?.status = ""
                self?.progress = 0
            }
        }
    }
}
