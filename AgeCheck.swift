import Foundation

/// R18 モードのときだけ使う年齢チェック。
/// 未成年を明確に指す語・18歳未満の年齢指定が含まれていたら理由を返す。
enum AgeCheck {
    private static let ja = [
        "子供", "子ども", "こども", "幼女", "幼児", "幼稚園", "児童", "ロリ", "ショタ",
        "小学生", "中学生", "高校生", "女子高生", "男子高校生", "未成年", "赤ちゃん", "乳児",
    ]
    private static let en = [
        "child", "children", "kid", "kids", "toddler", "infant", "baby", "loli", "lolicon",
        "shota", "shotacon", "underage", "preteen", "pre-teen", "little girl", "little boy",
        "elementary school", "middle school", "junior high", "high school student",
        "grade schooler",
    ]

    private static let enRegex: NSRegularExpression = {
        let alts = en.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<![a-z])(\(alts))(?![a-z])")
    }()

    private static let ageRegex = try! NSRegularExpression(
        pattern: "(\\d{1,2})\\s*(?:years?\\s*old|yo|y/o|歳|才|さい)"
    )

    /// 未成年とは関係ない言い回し（色名・服の名前など）は先に取り除く
    private static let allow = ["baby blue", "baby pink", "baby doll", "babydoll", "ゴスロリ"]

    static func check(_ text: String) -> String? {
        var t = text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
        for a in allow { t = t.replacingOccurrences(of: a, with: " ") }
        let range = NSRange(t.startIndex..., in: t)

        for w in ja where t.contains(w) {
            return "未成年を指す語（\(w)）が含まれています"
        }
        if let m = enRegex.firstMatch(in: t, range: range),
           let r = Range(m.range(at: 1), in: t) {
            return "未成年を指す語（\(t[r])）が含まれています"
        }
        for m in ageRegex.matches(in: t, range: range) {
            if let r = Range(m.range(at: 1), in: t), let age = Int(t[r]), age < 18,
               let whole = Range(m.range, in: t) {
                return "18歳未満の年齢指定（\(t[whole])）が含まれています"
            }
        }
        return nil
    }
}
