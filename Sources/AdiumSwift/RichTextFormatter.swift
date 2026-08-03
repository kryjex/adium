import SwiftUI

public enum RichTextFormatter {
    /// Dictionary of text shortcuts to unicode emojis
    public static let emoticonMap: [String: String] = [
        ":-)" : "😊",
        ":)"  : "😊",
        ":-D" : "😃",
        ":D"  : "😃",
        ":-(" : "🙁",
        ":("  : "🙁",
        ";-)" : "😉",
        ";)"  : "😉",
        ":-P" : "😋",
        ":P"  : "😋",
        ":p"  : "😋",
        ";-P" : "😋",
        ";P"  : "😋",
        ":-O" : "😮",
        ":O"  : "😮",
        ":o"  : "😮",
        "<3"  : "❤️",
        ":+1:": "👍",
        ":-1:": "👎",
        ":fire:": "🔥",
        ":rocket:": "🚀"
    ]

    /// Matches a plausible HTML tag: an opening `<` or `</`, followed immediately by a letter
    /// (real tag names), optional attributes, and a closing `>`. This intentionally does NOT match
    /// generic "less-than ... greater-than" text like "x<3 and y>2" or `Dictionary<String, Int>`,
    /// since those either don't start with a letter or aren't followed by whitespace/`/`/`>` right
    /// after the tag name.
    private static let htmlTagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "</?[a-zA-Z][a-zA-Z0-9]*(?:\\s[^<>]*)?/?>", options: [])
    }()

    /// Returns true only if `text` contains what looks like real HTML markup.
    private static func containsHTMLMarkup(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return htmlTagRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Replace textual emoticons with unicode emojis. Only standalone emoticons (delimited by
    /// whitespace or the ends of the text) are replaced, so substrings of ordinary text like the
    /// "<3" in "x<3" are left alone.
    public static func replaceEmoticons(in text: String) -> String {
        var result = text
        let sortedKeys = emoticonMap.keys.sorted { $0.count > $1.count }
        for key in sortedKeys {
            guard let replacement = emoticonMap[key], result.contains(key) else { continue }
            let pattern = "(?:^|(?<=\\s))" + NSRegularExpression.escapedPattern(for: key) + "(?=\\s|$)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
        }
        return result
    }

    /// Decode the common HTML entities libpurple/XMPP/Teams may send in message text
    /// (&amp; &lt; &gt; &quot; &apos; &#39; &nbsp; and numeric &#NNN;/&#xHH; forms).
    public static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = text
        let namedEntities: [(String, String)] = [
            ("&nbsp;", "\u{00A0}"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            // &amp; must be decoded last among named entities so that a (rare) double-encoded
            // sequence like "&amp;lt;" doesn't accidentally decode all the way to "<" in one pass.
            ("&amp;", "&")
        ]
        for (entity, decoded) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: decoded)
        }

        result = replaceNumericEntities(in: result, pattern: "&#([0-9]+);", radix: 10)
        result = replaceNumericEntities(in: result, pattern: "&#[xX]([0-9a-fA-F]+);", radix: 16)

        return result
    }

    private static func replaceNumericEntities(in text: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = 0
        for match in matches {
            let full = match.range
            result += nsText.substring(with: NSRange(location: lastEnd, length: full.location - lastEnd))
            let digits = nsText.substring(with: match.range(at: 1))
            if let code = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            } else {
                result += nsText.substring(with: full)
            }
            lastEnd = full.location + full.length
        }
        result += nsText.substring(with: NSRange(location: lastEnd, length: nsText.length - lastEnd))
        return result
    }

    /// Escape markdown-significant characters in raw, untrusted message text so that only markdown
    /// WE generate ourselves (from HTML conversion / auto-linking, below) ends up being interpreted
    /// by the AttributedString markdown parser. Without this, attacker-controlled text such as
    /// "[https://mybank.com](https://evil.example)" would render as a spoofed link, and stray
    /// `*`/`**`/`_` characters would restyle ordinary text.
    public static func escapeMarkdownSpecialCharacters(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "\\", "[", "]", "(", ")", "*", "_", "~", "`":
                result.append("\\")
                result.append(char)
            default:
                result.append(char)
            }
        }
        return result
    }

    /// Convert basic HTML tags (sent by libpurple / Jabber / Teams) to Markdown syntax.
    /// Only touches the text if it actually contains HTML-like markup; otherwise the text is
    /// returned unchanged (aside from entity decoding), so plain text like "if x<3 and y>2" or
    /// `Dictionary<String, Int>` is never mistaken for HTML and mangled.
    public static func convertHTMLToMarkdown(_ htmlText: String) -> String {
        guard containsHTMLMarkup(htmlText) else {
            return decodeHTMLEntities(htmlText)
        }

        var text = htmlText

        // Replace <br>, <br/>, <br /> with newline
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])

        // Replace <b>...</b> and <strong>...</strong> with **...**
        text = text.replacingOccurrences(of: "<b(?=[\\s/>])[^>]*>", with: "**", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</b>", with: "**", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<strong(?=[\\s/>])[^>]*>", with: "**", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</strong>", with: "**", options: .caseInsensitive)

        // Replace <i>...</i> and <em>...</em> with *...*
        text = text.replacingOccurrences(of: "<i(?=[\\s/>])[^>]*>", with: "*", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</i>", with: "*", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<em(?=[\\s/>])[^>]*>", with: "*", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</em>", with: "*", options: .caseInsensitive)

        // Replace <code>...</code> with `...`
        text = text.replacingOccurrences(of: "<code(?=[\\s/>])[^>]*>", with: "`", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</code>", with: "`", options: .caseInsensitive)

        // Convert <a href="URL">TEXT</a> -> [TEXT](URL)
        let linkPattern = "<a\\s+[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[$2]($1)")
        }

        // Strip out remaining unknown HTML tags (like <font ...>, <span>, etc.) using the same
        // strict "plausible tag" pattern used for detection above, rather than a catch-all
        // `<[^>]+>` that would also eat plain text like "if x<3 and y>2".
        let range = NSRange(text.startIndex..., in: text)
        text = htmlTagRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")

        // Decode entities last, so a decoded "&lt;" doesn't get reinterpreted as a tag by the
        // stripping pass above.
        text = decodeHTMLEntities(text)

        return text
    }

    /// Automatically convert standalone URLs (http:// or https://) into Markdown links [url](url),
    /// skipping URLs that are already inside an existing markdown link (as either the label or the
    /// target), so text already converted to `[url](url)` doesn't get re-linked into nested/broken
    /// markdown like `[[url](url)]([url](url))`.
    public static func autoLinkURLs(in text: String) -> String {
        let urlPattern = "(https?://[\\w\\d\\.#%/\\?=\\-\\+&\\~]+)"
        guard let urlRegex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
            return text
        }
        let linkSpanPattern = "\\[[^\\]\\n]*\\]\\([^)\\n]*\\)"
        guard let linkSpanRegex = try? NSRegularExpression(pattern: linkSpanPattern, options: []) else {
            return text
        }

        func autoLink(_ segment: String) -> String {
            guard !segment.isEmpty else { return segment }
            let range = NSRange(location: 0, length: (segment as NSString).length)
            return urlRegex.stringByReplacingMatches(in: segment, options: [], range: range, withTemplate: "[$1]($1)")
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let existingLinkSpans = linkSpanRegex.matches(in: text, options: [], range: fullRange)

        guard !existingLinkSpans.isEmpty else {
            return autoLink(text)
        }

        var result = ""
        var lastEnd = 0
        for match in existingLinkSpans {
            let gap = nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            result += autoLink(gap)
            result += nsText.substring(with: match.range)
            lastEnd = match.range.location + match.range.length
        }
        result += autoLink(nsText.substring(with: NSRange(location: lastEnd, length: nsText.length - lastEnd)))
        return result
    }

    /// Complete formatting pipeline: Emoticons -> escape raw text -> HTML -> Markdown -> AutoLink -> AttributedString.
    /// Emoticons go first because many of them contain characters the markdown escape would mangle
    /// (`:)` -> `:\)`) and emoji are not markdown-significant, so replacing them early is safe.
    /// The remaining raw text is escaped BEFORE any markdown is generated, so only
    /// formatter-generated markdown (from real HTML tags or auto-linked URLs) survives to be
    /// interpreted by the parser; attacker-controlled text containing markdown syntax renders as
    /// literal text instead.
    public static func formatMessage(_ rawText: String) -> AttributedString {
        let emoticonsReplaced = replaceEmoticons(in: rawText)
        let escaped = escapeMarkdownSpecialCharacters(emoticonsReplaced)
        let htmlConverted = convertHTMLToMarkdown(escaped)
        let autoLinked = autoLinkURLs(in: htmlConverted)

        do {
            return try AttributedString(
                markdown: autoLinked,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            return AttributedString(emoticonsReplaced)
        }
    }
}

public struct RichMessageView: View {
    let rawText: String
    let isFromMe: Bool

    public init(rawText: String, isFromMe: Bool = false) {
        self.rawText = rawText
        self.isFromMe = isFromMe
    }

    public var body: some View {
        Text(RichTextFormatter.formatMessage(rawText))
            .tint(isFromMe ? .yellow : .accentColor)
    }
}
