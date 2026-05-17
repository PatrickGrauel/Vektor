import Foundation
import AppKit

/// File-backed storage for images pasted into the Notes editor. Assets
/// live under `~/Library/Application Support/Vektor/notes-assets/` and
/// are referenced from note bodies via the custom URL scheme
/// `notes-asset://<filename>`. The preview view substitutes those URLs
/// with the real file URL before MarkdownUI hands them to AsyncImage.
///
/// Orphan cleanup runs at app launch (and again after every save) and
/// deletes files in the assets dir that aren't referenced by any
/// note's body. The body is the only source of truth for the in-use
/// set — there's no separate manifest to fall out of sync.
enum NotesAssets {

    static let scheme = "notes-asset"

    /// Returns (and creates if missing) the assets directory URL inside
    /// the app's sandboxed Application Support container.
    static func directory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory,
                              in: .userDomainMask,
                              appropriateFor: nil,
                              create: true)
        // Use a stable subfolder so a future "import / export notes"
        // feature has a single tree to bundle. The "Vektor" rather than
        // "Tally" namespace matches the app's product name in the
        // window chrome.
        let dir = base.appendingPathComponent("Vektor/notes-assets", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Resolve a `notes-asset://<filename>` URL into an on-disk file URL
    /// the preview can actually load. Returns `nil` if the URL doesn't
    /// match the scheme or the file is missing.
    static func resolve(_ url: URL) -> URL? {
        guard url.scheme == scheme else { return nil }
        // The filename can land in either `host` or the first path
        // component depending on how the URL was constructed. Try both.
        let name: String? = {
            if let host = url.host, !host.isEmpty { return host }
            let path = url.path
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }()
        guard let name, !name.isEmpty else { return nil }
        guard let dir = try? directory() else { return nil }
        let file = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Save an image as a PNG in the assets dir. Returns the
    /// `notes-asset://` URL the editor should insert into the body.
    /// PNG (rather than the original format) gives consistent decode
    /// behaviour in AsyncImage and avoids the orientation-handling
    /// quirks of JPEG / TIFF round-trips. File size is acceptable for
    /// the screenshot-pasting use case.
    static func saveImage(_ image: NSImage) throws -> URL {
        let dir = try directory()
        let id = UUID().uuidString.lowercased()
        let filename = "\(id).png"
        let fileURL = dir.appendingPathComponent(filename)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "notes-assets", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode pasted image as PNG."
            ])
        }
        try png.write(to: fileURL, options: .atomic)
        return URL(string: "\(scheme)://\(filename)")!
    }

    /// Walk every note's body, collect the set of referenced asset
    /// filenames, and delete any file in the assets dir that isn't in
    /// that set. Best-effort — silently swallows IO errors.
    static func purgeOrphans(referencedBy notes: [Note]) {
        guard let dir = try? directory() else { return }
        let fm = FileManager.default
        let referenced: Set<String> = {
            var s: Set<String> = []
            for note in notes {
                for name in referencedAssetNames(in: note.body) {
                    s.insert(name)
                }
            }
            return s
        }()
        let urls = (try? fm.contentsOfDirectory(at: dir,
                                                includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            if !referenced.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Filenames referenced by a single note body, parsed from
    /// `notes-asset://<filename>` URLs. Tolerates the URL appearing in
    /// `![alt](notes-asset://...)`, `[text](notes-asset://...)`, or
    /// bare in the text.
    static func referencedAssetNames(in body: String) -> [String] {
        let prefix = "\(scheme)://"
        var names: [String] = []
        var search = body.startIndex
        while let range = body.range(of: prefix, range: search..<body.endIndex) {
            let nameStart = range.upperBound
            // Filename ends at the next character that can't appear in
            // a URL path: `)`, `]`, whitespace, quote, end-of-string.
            var end = nameStart
            while end < body.endIndex {
                let ch = body[end]
                if ch == ")" || ch == "]" || ch == " " || ch == "\n"
                    || ch == "\t" || ch == "\"" || ch == "'" {
                    break
                }
                end = body.index(after: end)
            }
            let name = String(body[nameStart..<end])
            if !name.isEmpty { names.append(name) }
            search = end
        }
        return names
    }
}
