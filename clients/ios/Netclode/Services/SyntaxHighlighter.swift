import Foundation
import Highlightr
import SwiftUI

// MARK: - Syntax Highlighter Service

/// A shared service for syntax highlighting code using Highlightr
@MainActor
final class SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    private let highlightr: Highlightr?
    private var cachedResults: [CacheKey: NSAttributedString] = [:]
    private let cacheLimit = 100

    private struct CacheKey: Hashable {
        let code: String
        let language: String?
        let theme: String
    }

    // Theme names
    private var lightTheme = "github"
    private var darkTheme = "github-dark"
    private var currentTheme: String = "github-dark"

    private init() {
        self.highlightr = Highlightr()
        highlightr?.setTheme(to: darkTheme)
    }

    // MARK: - Theme Management

    /// Update the theme based on the color scheme
    func updateTheme(for colorScheme: ColorScheme) {
        let newTheme = colorScheme == .dark ? darkTheme : lightTheme
        if newTheme != currentTheme {
            currentTheme = newTheme
            highlightr?.setTheme(to: newTheme)
            // Clear cache when theme changes
            cachedResults.removeAll()
        }
    }

    // MARK: - Highlighting

    /// Highlight code and return NSAttributedString
    func highlight(
        _ code: String,
        language: String? = nil,
        colorScheme: ColorScheme = .dark
    ) -> NSAttributedString? {
        updateTheme(for: colorScheme)

        let cacheKey = CacheKey(
            code: code,
            language: language,
            theme: currentTheme
        )

        if let cached = cachedResults[cacheKey] {
            return cached
        }

        let result = highlightr?.highlight(code, as: language)

        if let result = result {
            // Manage cache size
            if cachedResults.count >= cacheLimit {
                cachedResults.removeAll()
            }
            cachedResults[cacheKey] = result
        }

        return result
    }

    /// Get syntax-colored segments for a single line
    func highlightLine(
        _ line: String,
        language: String?,
        colorScheme: ColorScheme
    ) -> [SyntaxSegment] {
        guard !line.isEmpty,
              let attributed = highlight(line, language: language, colorScheme: colorScheme)
        else {
            return [SyntaxSegment(text: line, color: nil)]
        }

        return extractSegments(from: attributed)
    }

    /// Extract color segments from NSAttributedString
    private func extractSegments(from attributed: NSAttributedString) -> [SyntaxSegment] {
        var segments: [SyntaxSegment] = []
        let fullRange = NSRange(location: 0, length: attributed.length)

        attributed.enumerateAttribute(
            .foregroundColor,
            in: fullRange,
            options: []
        ) { value, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            let color: Color? = {
                #if canImport(UIKit)
                if let uiColor = value as? UIColor {
                    return Color(uiColor)
                }
                #elseif canImport(AppKit)
                if let nsColor = value as? NSColor {
                    return Color(nsColor)
                }
                #endif
                return nil
            }()
            segments.append(SyntaxSegment(text: text, color: color))
        }

        return segments
    }

    /// Clear the cache
    func clearCache() {
        cachedResults.removeAll()
    }
}

// MARK: - Syntax Segment

/// A segment of text with an optional syntax color
struct SyntaxSegment: Identifiable {
    let id = UUID()
    let text: String
    let color: Color?
}

// MARK: - Language Detector

/// Detects programming language from file extensions
enum LanguageDetector {
    /// Detect language from file path
    static func language(for filePath: String) -> String? {
        let ext = (filePath as NSString).pathExtension.lowercased()
        return extensionMap[ext]
    }

    private static let extensionMap: [String: String] = [
        // Swift/Apple
        "swift": "swift",
        "m": "objectivec",
        "mm": "objectivec",
        "h": "objectivec",

        // C/C++
        "c": "c",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",

        // Web
        "js": "javascript",
        "jsx": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "html": "html",
        "htm": "html",
        "css": "css",
        "scss": "scss",
        "less": "less",
        "vue": "xml",
        "svelte": "xml",

        // Backend
        "py": "python",
        "rb": "ruby",
        "go": "go",
        "rs": "rust",
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin",
        "scala": "scala",
        "php": "php",
        "cs": "csharp",
        "fs": "fsharp",

        // Data/Config
        "json": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "ini",
        "xml": "xml",
        "plist": "xml",
        "md": "markdown",
        "sql": "sql",

        // Shell
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "fish": "bash",
        "ps1": "powershell",

        // Other
        "dockerfile": "dockerfile",
        "makefile": "makefile",
        "cmake": "cmake",
        "gradle": "gradle",
        "r": "r",
        "lua": "lua",
        "perl": "perl",
        "ex": "elixir",
        "exs": "elixir",
        "erl": "erlang",
        "hs": "haskell",
        "clj": "clojure",
        "lisp": "lisp",
        "proto": "protobuf",
        "graphql": "graphql",
        "tf": "hcl",
    ]
}
