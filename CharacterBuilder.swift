import SwiftUI

/// 選ぶだけでアニメキャラの見た目タグを組み立てる
struct CharacterBuilder: View {
    /// 組み立てたタグを返す
    var onApply: (String) -> Void

    typealias Option = (label: String, tag: String)

    static let gender: [Option] = [("女性", "1girl"), ("男性", "1boy")]
    static let hairColor: [Option] = [
        ("黒", "black hair"), ("茶", "brown hair"), ("金", "blonde hair"), ("銀", "silver hair"),
        ("白", "white hair"), ("赤", "red hair"), ("ピンク", "pink hair"), ("青", "blue hair"),
        ("水色", "light blue hair"), ("緑", "green hair"), ("紫", "purple hair"),
        ("グラデーション", "gradient hair"), ("メッシュ", "streaked hair"),
    ]
    static let hairLength: [Option] = [
        ("ベリーショート", "very short hair"), ("ショート", "short hair"), ("ボブ", "bob cut"),
        ("セミロング", "medium hair"), ("ロング", "long hair"), ("超ロング", "very long hair"),
    ]
    static let hairStyle: [Option] = [
        ("なし", ""), ("ストレート", "straight hair"), ("ウェーブ", "wavy hair"),
        ("ポニーテール", "ponytail"), ("ツインテール", "twintails"), ("サイドテール", "side ponytail"),
        ("三つ編み", "braid"), ("お団子", "hair bun"), ("姫カット", "hime cut"), ("アホ毛", "ahoge"),
    ]
    static let eyeColor: [Option] = [
        ("黒", "black eyes"), ("茶", "brown eyes"), ("赤", "red eyes"), ("青", "blue eyes"),
        ("緑", "green eyes"), ("紫", "purple eyes"), ("金", "yellow eyes"), ("ピンク", "pink eyes"),
        ("オッドアイ", "heterochromia"),
    ]
    static let eyeShape: [Option] = [
        ("なし", ""), ("つり目", "tsurime"), ("たれ目", "tareme"), ("ジト目", "jitome"),
        ("切れ長", "narrow eyes"),
    ]
    static let bodyType: [Option] = [
        ("なし", ""), ("スレンダー", "slender"), ("普通", ""), ("グラマー", "curvy"),
        ("筋肉質", "muscular"), ("長身", "tall"),
    ]
    static let outfit: [Option] = [
        ("なし", ""), ("Tシャツ", "t-shirt"), ("パーカー", "hoodie"), ("ワンピース", "sundress"),
        ("スーツ", "business suit"), ("メイド服", "maid"), ("着物", "kimono"),
        ("ドレス", "evening gown"), ("ナース服", "nurse"), ("軍服", "military uniform"),
        ("ゴスロリ", "gothic lolita fashion"), ("水着", "swimsuit"), ("ファンタジー鎧", "armor"),
        ("魔法使い", "witch hat, robe"),
    ]
    static let accessory: [Option] = [
        ("眼鏡", "glasses"), ("ヘアピン", "hairclip"), ("リボン", "hair ribbon"),
        ("カチューシャ", "hairband"), ("イヤリング", "earrings"), ("チョーカー", "choker"),
        ("ネコ耳", "cat ears"), ("キツネ耳", "fox ears"), ("角", "horns"), ("エルフ耳", "pointy ears"),
        ("ほくろ", "mole under eye"),
    ]
    static let expression: [Option] = [
        ("なし", ""), ("笑顔", "smile"), ("微笑み", "light smile"), ("照れ", "blush"),
        ("クール", "expressionless"), ("ドヤ顔", "smug"), ("怒り", "angry"), ("泣き", "crying"),
    ]

    @State private var g = 0
    @State private var hc = 0
    @State private var hl = 4
    @State private var hs = 0
    @State private var ec = 3
    @State private var es = 0
    @State private var bd = 0
    @State private var of = 0
    @State private var ex = 0
    @State private var acc: Set<Int> = []
    @Environment(\.dismiss) private var dismiss

    var tags: String {
        var t: [String] = [
            Self.gender[g].tag, Self.hairColor[hc].tag, Self.hairLength[hl].tag,
            Self.hairStyle[hs].tag, Self.eyeColor[ec].tag, Self.eyeShape[es].tag,
            Self.bodyType[bd].tag, Self.outfit[of].tag, Self.expression[ex].tag,
        ]
        t += acc.sorted().map { Self.accessory[$0].tag }
        return t.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    picker("性別", Self.gender, $g)
                    picker("体型", Self.bodyType, $bd)
                }
                Section("髪") {
                    picker("色", Self.hairColor, $hc)
                    picker("長さ", Self.hairLength, $hl)
                    picker("髪型", Self.hairStyle, $hs)
                }
                Section("目") {
                    picker("色", Self.eyeColor, $ec)
                    picker("形", Self.eyeShape, $es)
                }
                Section("服装・表情") {
                    picker("服", Self.outfit, $of)
                    picker("表情", Self.expression, $ex)
                }
                Section("アクセサリー（複数可）") {
                    ForEach(Self.accessory.indices, id: \.self) { i in
                        Button {
                            if acc.contains(i) { acc.remove(i) } else { acc.insert(i) }
                        } label: {
                            HStack {
                                Text(Self.accessory[i].label).foregroundStyle(.primary)
                                Spacer()
                                if acc.contains(i) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section("できあがるタグ") {
                    Text(tags).font(.caption.monospaced()).textSelection(.enabled)
                }
                Section {
                    Button("ランダムにする") { randomize() }
                }
            }
            .navigationTitle("かんたん作成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使う") {
                        onApply(tags)
                        dismiss()
                    }
                }
            }
        }
    }

    private func picker(_ title: String, _ opts: [Option], _ sel: Binding<Int>) -> some View {
        Picker(title, selection: sel) {
            ForEach(opts.indices, id: \.self) { i in Text(opts[i].label).tag(i) }
        }
    }

    private func randomize() {
        hc = Int.random(in: 0..<Self.hairColor.count)
        hl = Int.random(in: 0..<Self.hairLength.count)
        hs = Int.random(in: 0..<Self.hairStyle.count)
        ec = Int.random(in: 0..<Self.eyeColor.count)
        es = Int.random(in: 0..<Self.eyeShape.count)
        of = Int.random(in: 0..<Self.outfit.count)
        ex = Int.random(in: 0..<Self.expression.count)
        acc = Set((0..<Self.accessory.count).filter { _ in Int.random(in: 0..<5) == 0 })
    }
}
