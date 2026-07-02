import CoreGraphics
import Foundation
import NaturalLanguage

/// An error whose message is meant to be shown to the user as-is.
nonisolated struct UserMessageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// On-device language detection so the right voice can be picked automatically. Returns a
/// BCP-47 code like "en" or "he", or nil when unsure - never an error, detection is best-effort.
nonisolated enum LanguageDetect {
    static func detect(_ text: String) -> String? {
        let sample = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        guard sample.count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let lang = recognizer.dominantLanguage else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang] ?? 0
        return confidence >= 0.6 ? lang.rawValue : nil
    }
}

/// Guesses whether `text` reads right-to-left by counting strongly-directional letters
/// (Hebrew/Arabic vs. Latin etc.). Scans at most the first few thousand letters so it stays
/// cheap even for long documents.
nonisolated func isRtlText(_ text: String) -> Bool {
    var rtl = 0
    var ltr = 0
    for scalar in text.unicodeScalars {
        let v = scalar.value
        let isRtlScript = (0x0590...0x08FF).contains(v)      // Hebrew, Arabic, Syriac, Thaana...
            || (0xFB1D...0xFDFF).contains(v)                 // presentation forms
            || (0xFE70...0xFEFF).contains(v)
        if isRtlScript {
            rtl += 1
        } else if scalar.properties.isAlphabetic {
            ltr += 1
        }
        if rtl + ltr >= 4000 { break }
    }
    return rtl > ltr
}

/// Computes the centered rectangle that `container` fits a `width`×`height` image into.
nonisolated func fitRect(container: CGSize, width: CGFloat, height: CGFloat) -> CGRect {
    guard container.width > 0, container.height > 0, width > 0, height > 0 else { return .zero }
    let scale = min(container.width / width, container.height / height)
    let w = width * scale
    let h = height * scale
    return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
}

nonisolated extension String {
    /// Length in UTF-16 units - the unit every offset in this app uses.
    var utf16Count: Int { (self as NSString).length }
}
