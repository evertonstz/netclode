import MarkdownUI
import SwiftUI

// MARK: - MarkdownView

/// A SwiftUI view that renders Markdown content using MarkdownUI
struct MarkdownView: View {
    let content: String

    private var markdownContent: MarkdownContent {
        MarkdownContent(content)
    }

    var body: some View {
        Markdown(markdownContent)
            .markdownTheme(
                .gitHub
                    .text {
                        ForegroundColor(.primary)
                        BackgroundColor(nil)  // Remove the gray background from GitHub theme
                        FontSize(15)
                    }
                    .heading1 { configuration in
                        configuration.label
                            .markdownMargin(top: 16, bottom: 8)
                            .markdownTextStyle {
                                FontWeight(.semibold)
                                FontSize(20)
                            }
                    }
                    .heading2 { configuration in
                        configuration.label
                            .markdownMargin(top: 14, bottom: 6)
                            .markdownTextStyle {
                                FontWeight(.semibold)
                                FontSize(18)
                            }
                    }
                    .heading3 { configuration in
                        configuration.label
                            .markdownMargin(top: 12, bottom: 4)
                            .markdownTextStyle {
                                FontWeight(.semibold)
                                FontSize(16)
                            }
                    }
                    .heading4 { configuration in
                        configuration.label
                            .markdownMargin(top: 10, bottom: 4)
                            .markdownTextStyle {
                                FontWeight(.semibold)
                                FontSize(15)
                            }
                    }
                    .heading5 { configuration in
                        configuration.label
                            .markdownMargin(top: 8, bottom: 4)
                            .markdownTextStyle {
                                FontWeight(.semibold)
                                FontSize(15)
                            }
                    }
                    .heading6 { configuration in
                        configuration.label
                            .markdownMargin(top: 8, bottom: 4)
                            .markdownTextStyle {
                                FontWeight(.semibold)
                                FontSize(15)
                                ForegroundColor(.secondary)
                            }
                    }
                    .paragraph { configuration in
                        configuration.label
                            .markdownMargin(top: 0, bottom: 8)
                    }
                    .listItem { configuration in
                        configuration.label
                            .markdownMargin(top: 2, bottom: 2)
                    }
            )
            .markdownBlockStyle(\.codeBlock) { configuration in
                NetclodeCodeBlockView(configuration: configuration)
            }
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(13)
                BackgroundColor(MarkdownColors.codeBackground)
                ForegroundColor(MarkdownColors.codeText)
            }
            .markdownTextStyle(\.link) {
                ForegroundColor(MarkdownColors.brand)
                UnderlineStyle(.single)
            }
            .markdownBlockStyle(\.blockquote) { configuration in
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 4)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(MarkdownColors.brand.opacity(0.7))
                            .frame(width: 4)
                    }
            }
            .markdownTableBorderStyle(
                .init(color: .secondary.opacity(0.5), width: 1)
            )
            .markdownTableBackgroundStyle(
                .alternatingRows(Color.clear, MarkdownColors.codeBackground.opacity(0.3))
            )
            .textSelection(.enabled)
    }
}

// MARK: - Theme Colors

private enum MarkdownColors {
    static let codeBackground = Color.adaptive(
        light: Color(red: 0.95, green: 0.95, blue: 0.97),
        dark: Color(red: 0.12, green: 0.12, blue: 0.14)
    )

    static let codeText = Color.adaptive(
        light: Color(red: 0.2, green: 0.2, blue: 0.25),
        dark: Color(red: 0.9, green: 0.9, blue: 0.92)
    )

    static let brand = Color(red: 0.6, green: 0.5, blue: 0.7)
}

// MARK: - Code Block View

private struct NetclodeCodeBlockView: View {
    let configuration: CodeBlockConfiguration
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language and copy button
            HStack {
                if let language = configuration.language, !language.isEmpty {
                    Text(language.lowercased())
                        .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    copyToClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: TypeScale.caption, weight: .medium))
                        if copied {
                            Text("Copied")
                                .font(.system(size: TypeScale.caption, weight: .medium))
                        }
                    }
                    .foregroundStyle(copied ? .green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(13)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(MarkdownColors.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .markdownMargin(top: 8, bottom: 12)
        .animation(.easeInOut(duration: 0.2), value: copied)
    }

    private func copyToClipboard() {
        UIPasteboard.general.string = configuration.content
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        MarkdownView(content: """
        # Heading 1
        ## Heading 2
        ### Heading 3

        This is a paragraph with **bold**, *italic*, and `inline code`.

        Here's a [link](https://example.com) and some ~~strikethrough~~.

        > This is a blockquote
        > with multiple lines

        - Unordered item 1
        - Unordered item 2
        - Unordered item 3

        1. Ordered item 1
        2. Ordered item 2
        3. Ordered item 3

        ```swift
        func hello() {
            print("Hello, World!")
        }
        ```

        ---

        | Column 1 | Column 2 | Column 3 |
        |----------|----------|----------|
        | A        | B        | C        |
        | D        | E        | F        |
        """)
        .padding()
    }
}
