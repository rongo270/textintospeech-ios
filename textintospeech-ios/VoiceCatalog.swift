import AVFoundation
import Foundation

/// A voice with a friendly, no-real-names label like "Woman · Soft" or "Man · Strong (British)".
/// Some entries are derived "shapes" of a real voice (pitch/speed shifted), so languages with a
/// single system voice - like Hebrew - still offer a man's or a deeper voice.
struct FriendlyVoice: Identifiable, Equatable {
    let voice: AVSpeechSynthesisVoice
    var label: String
    /// Multipliers baked into this entry; 1 means the voice as Apple ships it.
    var pitchShift: Float = 1
    var rateShift: Float = 1
    /// Set on derived shapes ("man", "deep", ...) so they get their own stable id.
    var presetSlug: String? = nil

    var id: String { presetSlug.map { "\(voice.identifier)#\($0)" } ?? voice.identifier }

    static func == (a: FriendlyVoice, b: FriendlyVoice) -> Bool {
        a.id == b.id && a.label == b.label
    }
}

/// Curates the system voice list: removes duplicates (the same voice installed in several
/// qualities), gives every voice a descriptive label instead of its person name, and ranks the
/// list so the most pleasant voices come first. Works per language, including Hebrew.
enum VoiceCatalog {

    /// How many voices the picker shows before "Show all voices".
    static let mainCount = 5

    // MARK: - Dedupe

    /// Collapses voices that appear multiple times under the same name (compact + enhanced +
    /// premium installs of the same voice), keeping only the best-quality copy of each.
    static func dedupe(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        var best: [String: AVSpeechSynthesisVoice] = [:]
        var order: [String] = []
        for voice in voices {
            let key = dedupeKey(voice)
            if let existing = best[key] {
                if voice.quality.rawValue > existing.quality.rawValue { best[key] = voice }
            } else {
                best[key] = voice
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }

    private static func dedupeKey(_ voice: AVSpeechSynthesisVoice) -> String {
        // Same person name in the same language+region is the same voice; different regions
        // (e.g. a British vs American voice sharing a name) stay separate.
        "\(voice.language.lowercased())|\(baseName(voice).lowercased())"
    }

    /// "Samantha (Enhanced)" → "Samantha".
    private static func baseName(_ voice: AVSpeechSynthesisVoice) -> String {
        var name = voice.name
        for suffix in [" (Enhanced)", " (Premium)"] {
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Friendly labels

    private enum Kind { case woman, man, robot, other }

    private struct Persona {
        let kind: Kind
        let adjective: String?   // nil → plain "Woman"/"Man"
        let score: Int           // pleasantness, higher = better
    }

    /// Hand-tuned characters for the voices Apple ships. Score reflects how pleasant each voice
    /// sounds for long reading (natural modern voices high, old robotic compacts low).
    private static let personas: [String: Persona] = [
        // — English, female —
        "ava": Persona(kind: .woman, adjective: "Soft", score: 96),
        "zoe": Persona(kind: .woman, adjective: "Warm", score: 94),
        "samantha": Persona(kind: .woman, adjective: "Clear", score: 90),
        "allison": Persona(kind: .woman, adjective: "Bright", score: 80),
        "susan": Persona(kind: .woman, adjective: "Calm", score: 78),
        "joelle": Persona(kind: .woman, adjective: "Gentle", score: 76),
        "noelle": Persona(kind: .woman, adjective: "Soft", score: 74),
        "nicky": Persona(kind: .woman, adjective: "Friendly", score: 72),
        "vicki": Persona(kind: .woman, adjective: "Light", score: 50),
        "kathy": Persona(kind: .woman, adjective: "Plain", score: 20),
        "princess": Persona(kind: .woman, adjective: "Playful", score: 15),
        "karen": Persona(kind: .woman, adjective: "Clear", score: 79),
        "catherine": Persona(kind: .woman, adjective: "Soft", score: 77),
        "matilda": Persona(kind: .woman, adjective: "Warm", score: 75),
        "kate": Persona(kind: .woman, adjective: "Bright", score: 81),
        "serena": Persona(kind: .woman, adjective: "Elegant", score: 82),
        "martha": Persona(kind: .woman, adjective: "Calm", score: 80),
        "stephanie": Persona(kind: .woman, adjective: "Clear", score: 78),
        "moira": Persona(kind: .woman, adjective: "Warm", score: 70),
        "tessa": Persona(kind: .woman, adjective: "Clear", score: 69),
        "fiona": Persona(kind: .woman, adjective: "Calm", score: 68),
        "veena": Persona(kind: .woman, adjective: "Clear", score: 66),
        "isha": Persona(kind: .woman, adjective: "Bright", score: 67),
        // — English, male —
        "evan": Persona(kind: .man, adjective: "Soft", score: 92),
        "nathan": Persona(kind: .man, adjective: "Calm", score: 88),
        "tom": Persona(kind: .man, adjective: "Strong", score: 86),
        "aaron": Persona(kind: .man, adjective: "Clear", score: 84),
        "alex": Persona(kind: .man, adjective: "Warm", score: 85),
        "daniel": Persona(kind: .man, adjective: "Strong", score: 83),
        "arthur": Persona(kind: .man, adjective: "Soft", score: 82),
        "oliver": Persona(kind: .man, adjective: "Clear", score: 81),
        "gordon": Persona(kind: .man, adjective: "Strong", score: 74),
        "lee": Persona(kind: .man, adjective: "Calm", score: 73),
        "rishi": Persona(kind: .man, adjective: "Bright", score: 65),
        "fred": Persona(kind: .robot, adjective: nil, score: 30),
        "ralph": Persona(kind: .man, adjective: "Deep", score: 25),
        "junior": Persona(kind: .man, adjective: "Young", score: 15),
        // — Hebrew —
        "carmit": Persona(kind: .woman, adjective: "Clear", score: 90),
    ]

    /// Short accent tags for languages spoken in several regions (English mostly).
    private static let accentNames: [String: String] = [
        "US": "American", "GB": "British", "AU": "Australian", "IE": "Irish",
        "ZA": "South African", "IN": "Indian", "CA": "Canadian", "SCOTLAND": "Scottish",
    ]

    // MARK: - Building the list

    /// Builds the ranked, labelled voice list for one language group (already deduped).
    /// The most pleasant voices come first; labels are unique within the list.
    static func friendlyList(for voices: [AVSpeechSynthesisVoice]) -> [FriendlyVoice] {
        guard !voices.isEmpty else { return [] }

        // Rank: hand-tuned pleasantness first, then quality, then stable by name.
        let ranked = voices.sorted { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa > sb }
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            return a.name < b.name
        }

        // Accent tags only when the group actually mixes regions.
        let regions = Set(ranked.map(region))
        let majorityRegion = regions.contains("US") ? "US" : (region(ranked[0]))
        let tagAccents = regions.count > 1

        var labels: [String] = []
        for voice in ranked {
            var label = baseLabel(voice)
            if tagAccents, region(voice) != majorityRegion,
               let accent = accentNames[region(voice)] {
                label += " (\(accent))"
            }
            labels.append(label)
        }

        var entries = zip(ranked, labels).map { FriendlyVoice(voice: $0, label: $1) }
        entries += shapes(for: entries)

        // Same label twice → number them ("Woman · Soft 2").
        var seen: [String: Int] = [:]
        for i in entries.indices {
            let count = (seen[entries[i].label] ?? 0) + 1
            seen[entries[i].label] = count
            if count > 1 { entries[i].label += " \(count)" }
        }
        return entries
    }

    /// Derived voice shapes: when a language has no man's voice (Hebrew has only Carmit),
    /// pitch-shifted versions of the best voice fill the gap. The shifts are tuned to stay
    /// natural - deep enough to read as a man, never chipmunk or growl territory.
    private static func shapes(for real: [FriendlyVoice]) -> [FriendlyVoice] {
        guard let base = real.first else { return [] }
        var out: [FriendlyVoice] = []
        if real.count == 1 {
            let soft = kind(of: base.voice) == .man ? "Man · Soft" : "Woman · Soft"
            out.append(FriendlyVoice(voice: base.voice, label: soft,
                                     pitchShift: 1.12, rateShift: 0.96, presetSlug: "soft"))
        }
        if !real.contains(where: { kind(of: $0.voice) == .man }) {
            out.append(FriendlyVoice(voice: base.voice, label: "Man",
                                     pitchShift: 0.7, rateShift: 1.0, presetSlug: "man"))
            out.append(FriendlyVoice(voice: base.voice, label: "Man · Strong",
                                     pitchShift: 0.58, rateShift: 0.95, presetSlug: "deep"))
        }
        return out
    }

    /// The short list for the picker: the best voices, always including both a woman's and a
    /// man's voice when both are installed.
    static func mainList(_ all: [FriendlyVoice]) -> [FriendlyVoice] {
        guard all.count > mainCount else { return all }
        var main = Array(all.prefix(mainCount))
        for missing in [Kind.woman, Kind.man] {
            if !main.contains(where: { kind(of: $0.voice) == missing }),
               let best = all.first(where: { kind(of: $0.voice) == missing }) {
                main[main.count - 1] = best
            }
        }
        return main
    }

    // MARK: - Pieces

    private static func score(_ voice: AVSpeechSynthesisVoice) -> Int {
        let quality: Int
        switch voice.quality {
        case .premium: quality = 3000
        case .enhanced: quality = 2000
        default: quality = 1000
        }
        let persona = personas[baseName(voice).lowercased()]?.score ?? 55
        return quality + persona
    }

    private static func kind(of voice: AVSpeechSynthesisVoice) -> Kind {
        if let persona = personas[baseName(voice).lowercased()] { return persona.kind }
        switch voice.gender {
        case .female: return .woman
        case .male: return .man
        default: return .other
        }
    }

    private static func baseLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let persona = personas[baseName(voice).lowercased()]
        switch kind(of: voice) {
        case .robot: return "Robot"
        case .woman: return persona?.adjective.map { "Woman · \($0)" } ?? "Woman"
        case .man: return persona?.adjective.map { "Man · \($0)" } ?? "Man"
        case .other: return "Voice"
        }
    }

    /// "en-GB" → "GB"; "en-scotland" → "SCOTLAND".
    private static func region(_ voice: AVSpeechSynthesisVoice) -> String {
        let parts = voice.language.split(separator: "-")
        return parts.count > 1 ? parts.last!.uppercased() : ""
    }
}
