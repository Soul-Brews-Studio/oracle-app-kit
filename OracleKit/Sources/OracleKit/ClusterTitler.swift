import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Titles for the map's groups (issue #35): a group's keywords and the texts nearest its centre go to Apple's
/// on-device model, which answers with at most 5 words in the keywords' language. Thai: the model does not list Thai
/// (`supportedLanguages`, checked at run time), yet it answers in Thai — so a mostly-Thai group is still asked, and the
/// answer is kept only when it is Thai. Every other case (older macOS, Apple Intelligence off, a refusal, an answer in
/// the wrong script) leaves the title nil and the keywords name the group.
enum ClusterTitler {
    /// The title (nil: name it by its keywords) and who decided: "apple-fm", "apple-fm th" (Thai, not listed by
    /// Apple, the answer checked), or "keywords · <why>". `final` false: the model could not be asked right now (off,
    /// downloading, rate limited) — try again later rather than keep the keywords.
    /// `within`: the region a leaf is part of — the leaf is asked what sets it apart; `avoiding`: titles already
    /// taken nearby (an answer equal to one of them is not kept).
    static func title(keywords: [String], examples: [String], within region: String? = nil, avoiding taken: [String] = []) async -> (title: String?, model: String, final: Bool) {
        guard !keywords.isEmpty else { return (nil, "keywords · no words", true) }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) { return await apple(keywords: keywords, examples: examples, within: region, avoiding: taken) }
        #endif
        return (nil, "keywords · no on-device model before macOS 26", true)
    }

    /// Why the on-device model can't title right now (nil when it can) — Settings shows it.
    static var unavailable: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off — System Settings → Apple Intelligence & Siri"
            case .unavailable(.modelNotReady): return "Apple's model is still downloading"
            case .unavailable(.deviceNotEligible): return "this Mac can't run Apple's model"
            case .unavailable: return "Apple's model is unavailable"
            @unknown default: return "Apple's model is unavailable"
            }
        }
        #endif
        return "needs macOS 26"
    }

    static let instructions = "You name groups of notes. Give a title of at most 5 words, in the same language as the keywords. Reply with the title only."

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    private static func apple(keywords: [String], examples: [String], within region: String?, avoiding taken: [String]) async -> (title: String?, model: String, final: Bool) {
        let model = SystemLanguageModel.default
        if let why = unavailable { return (nil, "keywords · \(why)", false) }
        let thai = mostlyThai(keywords)
        let listed = !thai || model.supportedLanguages.contains { $0.languageCode?.identifier == "th" }
        var prompt = "Keywords: \(keywords.prefix(8).joined(separator: ", "))\nExamples:\n"
            + examples.prefix(3).map { "- \($0.prefix(90))" }.joined(separator: "\n")
        if let region { prompt += "\nThis group is one part of “\(region)”. Title what sets this part apart, not the whole." }
        if thai { prompt += "\nThe keywords are Thai: answer in Thai (ตอบเป็นภาษาไทย)." }
        if !taken.isEmpty { prompt += "\nDo not use these titles: \(taken.prefix(8).map { "“\($0)”" }.joined(separator: ", "))." }
        for attempt in 0..<3 {
            do {
                let session = LanguageModelSession(model: model, instructions: instructions)
                let r = try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 24))
                guard let t = clean(r.content) else { return (nil, "keywords · empty answer", true) }
                if thai, !isThai(t) { return (nil, "keywords · answer not in Thai", true) }
                if taken.contains(where: { Self.same($0, t) }) { return (nil, "keywords · same title as its region or a sibling", true) }
                return (t, listed ? "apple-fm" : "apple-fm th", true)
            } catch let e as LanguageModelSession.GenerationError {
                if case .rateLimited = e, attempt < 2 { try? await Task.sleep(for: .seconds(2 + 2 * attempt)); continue }
                switch e {
                case .guardrailViolation: return (nil, "keywords · the model declined", true)
                case .unsupportedLanguageOrLocale: return (nil, "keywords · language not supported", true)
                case .rateLimited: return (nil, "keywords · rate limited", false)
                default: return (nil, "keywords · \(e.localizedDescription.prefix(60))", true)
                }
            } catch {
                return (nil, "keywords · \(error.localizedDescription.prefix(60))", true)
            }
        }
        return (nil, "keywords · rate limited", false)
    }
    #endif

    /// The same title, whatever the case or the word order ("Cheapest Flights DMK" = "Cheapest DMK flights").
    static func same(_ a: String, _ b: String) -> Bool {
        let words = { (s: String) in Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)) }
        return words(a) == words(b)
    }

    /// Half or more of the keywords carry Thai letters.
    static func mostlyThai(_ words: [String]) -> Bool {
        !words.isEmpty && words.filter { $0.unicodeScalars.contains { (0x0E01...0x0E5B).contains($0.value) } }.count * 2 >= words.count
    }

    /// Half or more of the letters are Thai.
    static func isThai(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty && letters.filter { (0x0E01...0x0E5B).contains($0.value) }.count * 2 >= letters.count
    }

    /// The model's answer as a title: its first line without quotes, a "Title:" prefix or end punctuation, at most
    /// 6 words and 48 characters (cut at a word). Nil when nothing is left.
    static func clean(_ answer: String) -> String? {
        var t = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        t = t.trimmingCharacters(in: .whitespaces)
        for p in ["Title:", "title:", "TITLE:", "หัวข้อ:", "ชื่อ:"] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        let edge = CharacterSet(charactersIn: "\"'“”‘’*#`.:;,!–—-").union(.whitespaces)
        t = t.trimmingCharacters(in: edge)
        var words = t.split(separator: " ").map(String.init)
        if words.count > 6 { words = Array(words.prefix(6)) }
        t = words.joined(separator: " ")
        while t.count > 48, words.count > 1 { words.removeLast(); t = words.joined(separator: " ") }
        if t.count > 48 { t = String(t.prefix(48)) }
        t = t.trimmingCharacters(in: edge)
        return t.isEmpty ? nil : t
    }
}
