import SwiftUI
import MarkdownUI

/// Read-only markdown rendering of the note body. Two pre-processing
/// passes happen before MarkdownUI sees the text:
///
///   1. `notes-asset://<file>` image URLs are rewritten to `file://...`
///      pointing at the real on-disk asset. The asset dir is inside the
///      app's sandbox container, so `file://` URLs always resolve.
///   2. `[[Wiki Link]]` tokens are rewritten as standard markdown links
///      with a `note://` scheme. The pane installs an `openURL` handler
///      that intercepts that scheme and switches the selected note.
struct NotesPreview: View {
    let text: String
    /// Map of `lowercase note title` → note id, used to resolve wiki
    /// links to real notes. Stale targets render as plain text — Bear
    /// renders broken wiki links the same way.
    let titleIndex: [String: UUID]
    let onOpenWikiLink: (UUID) -> Void

    var body: some View {
        ScrollView {
            Markdown(processedBody)
                .markdownTheme(.notesTheme)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(TallyTheme.background)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "note" {
                // Note titles are URL-encoded so spaces survive the
                // round trip. Decode before lookup.
                let target = (url.host ?? url.path)
                    .removingPercentEncoding ?? ""
                if let id = titleIndex[target.lowercased()] {
                    onOpenWikiLink(id)
                    return .handled
                }
                return .discarded
            }
            return .systemAction
        })
    }

    /// Body with `notes-asset://` images and `[[wiki]]` links rewritten
    /// so MarkdownUI can render them natively.
    private var processedBody: String {
        var s = text
        s = rewriteAssetURLs(in: s)
        s = rewriteWikiLinks(in: s)
        return s
    }

    private func rewriteAssetURLs(in source: String) -> String {
        let prefix = "\(NotesAssets.scheme)://"
        var out = ""
        var idx = source.startIndex
        while let range = source.range(of: prefix, range: idx..<source.endIndex) {
            out.append(contentsOf: source[idx..<range.lowerBound])
            let nameStart = range.upperBound
            var end = nameStart
            while end < source.endIndex {
                let ch = source[end]
                if ch == ")" || ch == "]" || ch == " " || ch == "\n"
                    || ch == "\t" || ch == "\"" || ch == "'" {
                    break
                }
                end = source.index(after: end)
            }
            let filename = String(source[nameStart..<end])
            if let assetURL = URL(string: "\(prefix)\(filename)"),
               let resolved = NotesAssets.resolve(assetURL) {
                out.append(contentsOf: resolved.absoluteString)
            } else {
                // File missing — keep the original token so the missing
                // image is visible to the user.
                out.append(prefix)
                out.append(filename)
            }
            idx = end
        }
        out.append(contentsOf: source[idx..<source.endIndex])
        return out
    }

    private func rewriteWikiLinks(in source: String) -> String {
        var out = ""
        var i = source.startIndex
        while i < source.endIndex {
            if source[i] == "[",
               source.index(after: i) < source.endIndex,
               source[source.index(after: i)] == "[" {
                let openEnd = source.index(i, offsetBy: 2)
                if let closeRange = source.range(of: "]]",
                                                 range: openEnd..<source.endIndex) {
                    let inner = String(source[openEnd..<closeRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    if !inner.isEmpty,
                       let encoded = inner.addingPercentEncoding(
                            withAllowedCharacters: .urlHostAllowed) {
                        out.append("[")
                        out.append(inner)
                        out.append("](note://")
                        out.append(encoded)
                        out.append(")")
                        i = closeRange.upperBound
                        continue
                    }
                }
            }
            out.append(source[i])
            i = source.index(after: i)
        }
        return out
    }
}

private extension Theme {
    /// Notes-pane theme — Tally palette applied on top of MarkdownUI's
    /// default block layout. Keeps default heading hierarchy, list
    /// markers, blockquote indent etc., overriding only the colours and
    /// the inline-code background so they read against `TallyTheme`'s
    /// navy / cream backgrounds.
    static var notesTheme: Theme {
        Theme()
            .text {
                ForegroundColor(TallyTheme.text)
                FontSize(15)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                BackgroundColor(TallyTheme.codeSurface)
                ForegroundColor(TallyTheme.accent)
            }
            .link {
                ForegroundColor(TallyTheme.accent)
                UnderlineStyle(.single)
            }
            .heading1 { config in
                config.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(.em(1.7))
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading2 { config in
                config.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(.em(1.4))
                    }
                    .markdownMargin(top: 14, bottom: 6)
            }
            .heading3 { config in
                config.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.18))
                    }
                    .markdownMargin(top: 12, bottom: 4)
            }
            .blockquote { config in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(TallyTheme.divider)
                        .frame(width: 3)
                    config.label
                        .foregroundColor(TallyTheme.muted)
                }
            }
            .codeBlock { config in
                ScrollView(.horizontal, showsIndicators: false) {
                    config.label
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.88))
                            ForegroundColor(TallyTheme.text)
                        }
                }
                .background(TallyTheme.codeSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 8, bottom: 8)
            }
    }
}
