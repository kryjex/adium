import SwiftUI

public enum RichTextFormatter {
    /// This is a dictionary of text shortcuts to unicode emojis.
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

    /// Match a plausible HTML tag.
    /// This includes an opening bracket, a letter, optional attributes, and a closing bracket.
    /// This does not match generic less-than or greater-than text.
    private static let htmlTagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "</?[a-zA-Z][a-zA-Z0-9]*(?:\\s[^<>]*)?/?>", options: [])
    }()

    /// Return true only if the text contains real HTML markup.
    private static func containsHTMLMarkup(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return htmlTagRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Replace textual emoticons with unicode emojis.
    /// Replace only standalone emoticons.
    /// Leave substrings of ordinary text alone.
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

    /// Decode the common HTML entities in message text.
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
            // Decode the ampersand entity last among named entities.
            // This prevents a double-encoded sequence from decoding completely in one pass.
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

    /// Escape markdown characters in raw message text.
    /// This ensures that the parser interprets only our markdown.
    /// This prevents attacker-controlled text from rendering as a spoofed link.
    /// This also prevents stray characters from restyling ordinary text.
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

    /// Convert basic HTML tags to Markdown syntax.
    /// Modify the text only if it contains HTML markup.
    /// Return plain text unchanged to prevent mangling.
    public static func convertHTMLToMarkdown(_ htmlText: String) -> String {
        guard containsHTMLMarkup(htmlText) else {
            return decodeHTMLEntities(htmlText)
        }

        var text = htmlText

        // Replace line break tags with a newline character.
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])

        // Replace bold tags with double asterisks.
        text = text.replacingOccurrences(of: "<b(?=[\\s/>])[^>]*>", with: "**", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</b>", with: "**", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<strong(?=[\\s/>])[^>]*>", with: "**", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</strong>", with: "**", options: .caseInsensitive)

        // Replace italic tags with single asterisks.
        text = text.replacingOccurrences(of: "<i(?=[\\s/>])[^>]*>", with: "*", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</i>", with: "*", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<em(?=[\\s/>])[^>]*>", with: "*", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</em>", with: "*", options: .caseInsensitive)

        // Replace code tags with backticks.
        text = text.replacingOccurrences(of: "<code(?=[\\s/>])[^>]*>", with: "`", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</code>", with: "`", options: .caseInsensitive)

        // Convert HTML links to Markdown links.
        let linkPattern = "<a\\s+[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[$2]($1)")
        }

        // Strip out remaining unknown HTML tags.
        // Use the strict plausible tag pattern.
        // Do not use a catch-all pattern that alters plain text.
        let range = NSRange(text.startIndex..., in: text)
        text = htmlTagRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")

        // Decode entities last.
        // This prevents the stripping pass from interpreting a decoded bracket as a tag.
        text = decodeHTMLEntities(text)

        return text
    }

    /// Convert standalone URLs into Markdown links automatically.
    /// Skip URLs that are already inside an existing Markdown link.
    /// This prevents nested or broken Markdown.
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

    /// Run the complete formatting pipeline.
    /// Replace emoticons first to prevent mangling by the markdown escape.
    /// Escape the remaining raw text before you generate any markdown.
    /// This ensures that the parser interprets only formatter-generated markdown.
    /// This causes attacker-controlled text to render as literal text.
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
            .textSelection(.enabled)
    }
}
