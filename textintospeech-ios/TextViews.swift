import SwiftUI
import UIKit

/// The Read tab's editable text area: a UITextView whose spoken sentence/word is marked with a
/// background color attribute *without* replacing the text, so the caret and scroll position
/// survive. The text is replaced wholesale only when `version` bumps (a new document loaded).
struct HighlightTextEditor: UIViewRepresentable {
    let initialText: String
    let version: Int
    let highlight: NSRange?
    let fontSize: CGFloat
    let rtl: Bool
    let textColor: UIColor
    let followHighlight: Bool
    let onTextChanged: (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView(usingTextLayoutManager: false)
        tv.backgroundColor = .clear
        tv.delegate = context.coordinator
        tv.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.adjustsFontForContentSizeCategory = false
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self

        if c.appliedVersion != version {
            c.appliedVersion = version
            c.programmatic = true
            tv.text = initialText
            c.programmatic = false
            c.styleKey = nil          // force re-style below
            c.lastHighlight = nil
        }

        let key = StyleKey(fontSize: fontSize, rtl: rtl, color: textColor)
        if c.styleKey != key {
            c.styleKey = key
            let attrs = Self.attributes(fontSize: fontSize, rtl: rtl, color: textColor)
            tv.typingAttributes = attrs
            let full = NSRange(location: 0, length: (tv.text as NSString).length)
            tv.textStorage.beginEditing()
            tv.textStorage.setAttributes(attrs, range: full)
            tv.textStorage.endEditing()
            c.lastHighlight = nil     // setAttributes wiped the background too
        }

        if c.lastHighlight != highlight {
            let full = NSRange(location: 0, length: (tv.text as NSString).length)
            tv.textStorage.beginEditing()
            if let old = c.lastHighlight, old.location + old.length <= full.length {
                tv.textStorage.removeAttribute(.backgroundColor, range: old)
            } else {
                tv.textStorage.removeAttribute(.backgroundColor, range: full)
            }
            if let new = highlight, new.location >= 0, new.location + new.length <= full.length, new.length > 0 {
                tv.textStorage.addAttribute(.backgroundColor, value: highlightUIColor, range: new)
                if followHighlight {
                    tv.scrollRangeToVisible(new)
                }
            }
            tv.textStorage.endEditing()
            c.lastHighlight = highlight
        }
    }

    nonisolated static func attributes(fontSize: CGFloat, rtl: Bool, color: UIColor) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.3
        para.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        para.alignment = .natural
        return [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    struct StyleKey: Equatable {
        let fontSize: CGFloat
        let rtl: Bool
        let color: UIColor
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HighlightTextEditor
        var appliedVersion = Int.min
        var programmatic = false
        var styleKey: StyleKey?
        var lastHighlight: NSRange?

        init(_ parent: HighlightTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard !programmatic else { return }
            lastHighlight = nil   // edits shift offsets; the app stops reading anyway
            parent.onTextChanged(textView.text)
        }
    }
}

/// Read-only text with the spoken range highlighted - used by the photo reader's text mode
/// (scrollable, auto-follows the highlight) and by the book pages (fixed, tap-a-line-to-read).
struct ReadOnlyHighlightText: UIViewRepresentable {
    let text: String
    let highlight: NSRange?
    let fontSize: CGFloat
    let rtl: Bool
    let textColor: UIColor
    var scrollEnabled = true
    var autoScrollToHighlight = false
    var lineHeightMultiple: CGFloat = 1.35
    /// Called with the UTF-16 offset of the start of the tapped visual line.
    var onTapLineStart: ((Int) -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView(usingTextLayoutManager: false)
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = scrollEnabled
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.adjustsFontForContentSizeCategory = false
        if onTapLineStart != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onTap(_:)))
            tv.addGestureRecognizer(tap)
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self

        let key = ContentKey(text: text, fontSize: fontSize, rtl: rtl, color: textColor, highlight: highlight)
        if c.contentKey != key {
            c.contentKey = key
            let attrs = HighlightTextEditor.attributes(fontSize: fontSize, rtl: rtl, color: textColor)
            var para = attrs[.paragraphStyle] as! NSMutableParagraphStyle
            para = para.mutableCopy() as! NSMutableParagraphStyle
            para.lineHeightMultiple = lineHeightMultiple
            var merged = attrs
            merged[.paragraphStyle] = para
            let styled = NSMutableAttributedString(string: text, attributes: merged)
            if let h = highlight, h.location >= 0, h.length > 0, h.location + h.length <= styled.length {
                styled.addAttribute(.backgroundColor, value: highlightUIColor, range: h)
            }
            tv.attributedText = styled
            if autoScrollToHighlight, scrollEnabled, let h = highlight, h.location >= 0, h.location + h.length <= styled.length {
                tv.scrollRangeToVisible(h)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    struct ContentKey: Equatable {
        let text: String
        let fontSize: CGFloat
        let rtl: Bool
        let color: UIColor
        let highlight: NSRange?
    }

    final class Coordinator: NSObject {
        var parent: ReadOnlyHighlightText
        var contentKey: ContentKey?

        init(_ parent: ReadOnlyHighlightText) { self.parent = parent }

        @objc func onTap(_ gesture: UITapGestureRecognizer) {
            guard let tv = gesture.view as? UITextView, tv.textStorage.length > 0 else { return }
            var point = gesture.location(in: tv)
            point.x -= tv.textContainerInset.left
            point.y -= tv.textContainerInset.top
            let lm = tv.layoutManager
            let glyphIndex = lm.glyphIndex(for: point, in: tv.textContainer)
            guard glyphIndex < lm.numberOfGlyphs else { return }
            var lineGlyphRange = NSRange(location: 0, length: 0)
            lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            let charRange = lm.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            // Anchor to the start of the tapped line - the intuitive spot to read from.
            parent.onTapLineStart?(charRange.location)
        }
    }
}

/// Measures `text` once with TextKit and returns the start UTF-16 offset of each
/// screen-sized page - the port of the Android reader's `paginate`.
nonisolated func paginate(text: String, fontSize: CGFloat, rtl: Bool, pageSize: CGSize) -> [Int] {
    guard !text.isEmpty, pageSize.width > 8, pageSize.height > 8 else { return [0] }
    let attrs = HighlightTextEditor.attributes(fontSize: fontSize, rtl: rtl, color: .black)
    var merged = attrs
    let para = (attrs[.paragraphStyle] as! NSMutableParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
    para.lineHeightMultiple = 1.35
    merged[.paragraphStyle] = para

    let storage = NSTextStorage(string: text, attributes: merged)
    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)

    // The page views inset their text by 8pt (ReadOnlyHighlightText); measure the same box.
    let inset: CGFloat = 8
    let box = CGSize(width: pageSize.width - inset * 2, height: pageSize.height - inset * 2)

    var starts: [Int] = []
    var glyphIndex = 0
    while true {
        let container = NSTextContainer(size: box)
        container.lineFragmentPadding = 5   // UITextView default
        layoutManager.addTextContainer(container)
        let glyphRange = layoutManager.glyphRange(for: container)
        if glyphRange.length == 0 { break }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        starts.append(charRange.location)
        glyphIndex = NSMaxRange(glyphRange)
        if glyphIndex >= layoutManager.numberOfGlyphs { break }
    }
    return starts.isEmpty ? [0] : starts
}

/// Which page (index into `starts`) contains char `offset`.
nonisolated func pageForOffset(_ starts: [Int], _ offset: Int) -> Int {
    guard offset > 0 else { return 0 }
    return max(starts.lastIndex { $0 <= offset } ?? 0, 0)
}
