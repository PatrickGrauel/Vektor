import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Composes genuine, separately captured app images. This never draws app UI.
// Run through render.sh so compiler caches stay outside the working checkout.

struct Manifest: Decodable {
    let schemaVersion: Int
    let canvas: Canvas
    let style: Style
    let frames: [Frame]
}
struct Canvas: Decodable { let width: Int; let height: Int }
struct Style: Decodable {
    let background: String
    let ink: String
    let muted: String
    let accent: String
}
struct Frame: Decodable {
    let id: String
    let headline: String
    let subline: String
    let capture: String
    let captureKind: String
    let appearance: String
    let expectedCapture: CaptureSize
    let sourceTextSizePx: Double
    let typedContent: String
    let captureNotes: String
}
struct CaptureSize: Decodable { let minWidth: Int; let minHeight: Int }
struct Capture {
    let frame: Frame
    let url: URL
    let image: CGImage
    let rect: CGRect
    let scale: Double
}
struct ToolFailure: Error, CustomStringConvertible { let description: String }

let canvasWidth = 2880
let canvasHeight = 1800
let screenshotSlot = CGRect(x: 150, y: 490, width: 2580, height: 1190)
let minimumOutputTextPx = 24.0 // Production heuristic, not an Apple requirement.
let fileManager = FileManager.default

func fail(_ message: String) throws -> Never { throw ToolFailure(description: message) }
func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
func color(_ hex: String) throws -> NSColor {
    guard hex.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil,
          let value = UInt32(hex.dropFirst(), radix: 16) else {
        try fail("Invalid opaque RGB color: \(hex); use #RRGGBB.")
    }
    return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                   green: Double((value >> 8) & 255) / 255,
                   blue: Double(value & 255) / 255, alpha: 1)
}
func bottomRect(_ top: CGRect, height: CGFloat = 1800) -> CGRect {
    CGRect(x: top.minX, y: height - top.maxY, width: top.width, height: top.height)
}
func textAttributes(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byClipping
    return [.font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph]
}
func fitsSingleLine(_ text: String, size: CGFloat, weight: NSFont.Weight, width: CGFloat) -> Bool {
    guard !text.contains("\n") && !text.contains("\r") else { return false }
    return (text as NSString).size(withAttributes: textAttributes(size: size, weight: weight, color: .black)).width <= width
}
func validateManifest(_ manifest: Manifest) throws {
    guard manifest.schemaVersion == 1 else { try fail("Only schemaVersion 1 is supported.") }
    guard manifest.canvas.width == canvasWidth && manifest.canvas.height == canvasHeight else {
        try fail("Mac screenshots must use this kit's 2880×1800 canvas.")
    }
    for value in [manifest.style.background, manifest.style.ink, manifest.style.muted, manifest.style.accent] {
        _ = try color(value)
    }
    guard (1...10).contains(manifest.frames.count) else { try fail("Provide 1–10 ordered screenshot frames.") }
    var ids = Set<String>()
    for (index, frame) in manifest.frames.enumerated() {
        guard frame.id.range(of: #"^[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil,
              frame.id.hasPrefix(String(format: "%02d-", index + 1)), ids.insert(frame.id).inserted else {
            try fail("Frame IDs must be unique and ordered: 01-topic, 02-topic… (got \(frame.id)).")
        }
        guard !frame.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fitsSingleLine(frame.headline, size: 96, weight: .semibold, width: 2580) else {
            try fail("\(frame.id): headline must fit one line at 96 px within 2580 px.")
        }
        guard !frame.subline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fitsSingleLine(frame.subline, size: 42, weight: .regular, width: 2580) else {
            try fail("\(frame.id): subline must fit one line at 42 px within 2580 px.")
        }
        guard ["window", "desktop"].contains(frame.captureKind) else {
            try fail("\(frame.id): captureKind must be window or desktop; mock UI is unsupported.")
        }
        guard ["light", "dark"].contains(frame.appearance) else {
            try fail("\(frame.id): appearance must describe the actual light or dark capture.")
        }
        guard ["png", "jpg", "jpeg"].contains(URL(fileURLWithPath: frame.capture).pathExtension.lowercased()),
              !frame.capture.isEmpty else { try fail("\(frame.id): capture must name a local PNG/JPEG.") }
        guard frame.expectedCapture.minWidth >= 1800, frame.expectedCapture.minHeight >= 1000,
              frame.expectedCapture.minWidth <= 12000, frame.expectedCapture.minHeight <= 12000 else {
            try fail("\(frame.id): raw capture minimum must be at least 1800×1000 and at most 12000×12000.")
        }
        guard frame.sourceTextSizePx.isFinite, frame.sourceTextSizePx >= minimumOutputTextPx,
              frame.sourceTextSizePx <= 200 else {
            try fail("\(frame.id): declare a measured raw calculation text size in pixels (24–200).")
        }
        guard !frame.typedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !frame.captureNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try fail("\(frame.id): typedContent and captureNotes are required for a repeatable real capture.")
        }
    }
}
func captureURL(_ frame: Frame, manifestURL: URL) -> URL {
    if frame.capture.hasPrefix("/") { return URL(fileURLWithPath: frame.capture).standardizedFileURL }
    return manifestURL.deletingLastPathComponent().appendingPathComponent(frame.capture).standardizedFileURL
}
func readCapture(_ frame: Frame, manifestURL: URL) throws -> Capture {
    let url = captureURL(frame, manifestURL: manifestURL)
    guard fileManager.fileExists(atPath: url.path) else {
        try fail("\(frame.id): missing real capture at \(url.path). Capture the app before rendering.")
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else {
        try fail("\(frame.id): capture is not a readable single-frame image.")
    }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        try fail("\(frame.id): cannot inspect image metadata.")
    }
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    guard orientation == 1 else { try fail("\(frame.id): normalize image orientation before use.") }
    guard image.width >= frame.expectedCapture.minWidth, image.height >= frame.expectedCapture.minHeight else {
        try fail("\(frame.id): capture \(image.width)×\(image.height) is below \(frame.expectedCapture.minWidth)×\(frame.expectedCapture.minHeight). Use a Retina capture.")
    }
    guard image.width <= 12000, image.height <= 12000 else { try fail("\(frame.id): capture exceeds the 12000 px processing limit.") }
    let scale = min(screenshotSlot.width / Double(image.width), screenshotSlot.height / Double(image.height))
    guard scale <= 1.0001 else {
        try fail("\(frame.id): capture would need \(String(format: "%.1f", scale * 100))% enlargement. Capture at higher resolution.")
    }
    let finalTextSize = frame.sourceTextSizePx * scale
    guard finalTextSize >= minimumOutputTextPx else {
        try fail("\(frame.id): declared calculation text would render at \(String(format: "%.1f", finalTextSize)) px, below 24 px. Use a shorter/wider real capture; do not fake enlarged UI.")
    }
    let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
    let rect = CGRect(x: screenshotSlot.midX - size.width / 2,
                      y: screenshotSlot.midY - size.height / 2, width: size.width, height: size.height)
    return Capture(frame: frame, url: url, image: image, rect: rect, scale: scale)
}
func makeCanvas(width: Int, height: Int) throws -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        try fail("Cannot allocate opaque sRGB canvas.")
    }
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    return context
}
func drawText(_ text: String, in top: CGRect, size: CGFloat, weight: NSFont.Weight,
              color: NSColor, height: CGFloat = 1800) {
    (text as NSString).draw(in: bottomRect(top, height: height),
                           withAttributes: textAttributes(size: size, weight: weight, color: color))
}
func render(_ capture: Capture, style: Style) throws -> CGImage {
    let context = try makeCanvas(width: canvasWidth, height: canvasHeight)
    let background = try color(style.background)
    context.setFillColor(background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    drawText("Vektor", in: CGRect(x: 150, y: 96, width: 2580, height: 52),
             size: 34, weight: .medium, color: try color(style.accent))
    drawText(capture.frame.headline, in: CGRect(x: 150, y: 175, width: 2580, height: 124),
             size: 96, weight: .semibold, color: try color(style.ink))
    drawText(capture.frame.subline, in: CGRect(x: 154, y: 318, width: 2576, height: 64),
             size: 42, weight: .regular, color: try color(style.muted))
    NSGraphicsContext.restoreGraphicsState()
    let target = bottomRect(capture.rect)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -16), blur: 34,
                      color: NSColor(srgbRed: 0.055, green: 0.082, blue: 0.129, alpha: 0.18).cgColor)
    // Opaque backing prevents raw window corner transparency from reaching the PNG.
    context.setFillColor(background.cgColor)
    context.fill(target)
    context.draw(capture.image, in: target)
    context.restoreGState()
    guard let image = context.makeImage() else { try fail("Could not render \(capture.frame.id).") }
    return image
}
func writePNG(_ image: CGImage, to url: URL) throws {
    // Build data first; atomic writes avoid half-written upload files on failure.
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        try fail("Cannot create PNG encoder.")
    }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGsRGBIntent: 0]] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { try fail("PNG encoding failed for \(url.lastPathComponent).") }
    try (data as Data).write(to: url, options: .atomic)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let result = CGImageSourceCreateImageAtIndex(source, 0, nil),
          result.width == image.width && result.height == image.height,
          [.none, .noneSkipFirst, .noneSkipLast].contains(result.alphaInfo),
          result.colorSpace?.model == .rgb else {
        try fail("Output verification failed: \(url.path) must be RGB without alpha.")
    }
}
func contactSheet(_ images: [(String, CGImage)], background: NSColor, ink: NSColor) throws -> CGImage {
    let columns = 2
    let rows = (images.count + columns - 1) / columns
    let width = 1500
    let tileWidth = 690.0
    let tileHeight = tileWidth / 1.6
    let rowHeight = tileHeight + 80
    let height = Int(Double(rows) * rowHeight + 40)
    let context = try makeCanvas(width: width, height: height)
    context.setFillColor(background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    for (index, item) in images.enumerated() {
        let x = 40.0 + Double(index % columns) * 730
        let y = 40.0 + Double(index / columns) * rowHeight
        context.draw(item.1, in: bottomRect(CGRect(x: x, y: y, width: tileWidth, height: tileHeight), height: CGFloat(height)))
        drawText(item.0, in: CGRect(x: x, y: y + tileHeight + 12, width: tileWidth, height: 40),
                 size: 23, weight: .medium, color: ink, height: CGFloat(height))
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else { try fail("Cannot render contact sheet.") }
    return image
}
func usage() {
    print("""
    Usage: scripts/app-store/render.sh --manifest docs/app-store/screenshots.json [mode]
      --validate          Check manifest, copy fit, and report capture availability; no files written.
      --check-captures    Also require every real image, sufficient resolution, and legible scaling.
      --output DIR        Render all opaque 2880×1800 sRGB PNGs, contact sheet, and build report.
    Default mode: --validate. Raw capture paths resolve relative to the manifest.
    The tool never synthesizes UI. Capture authenticity and visual QA remain a human check.
    """)
}
do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var manifestPath: String?
    var mode = "validate"
    var outputPath: String?
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--manifest", "--output":
            guard !arguments.isEmpty else { try fail("\(argument) requires a path.") }
            let value = arguments.removeFirst()
            if argument == "--manifest" { manifestPath = value }
            else { outputPath = value; mode = "render" }
        case "--validate": mode = "validate"
        case "--check-captures": mode = "check"
        case "--help", "-h": usage(); exit(0)
        default: try fail("Unknown argument: \(argument).")
        }
    }
    guard let manifestPath else { usage(); try fail("--manifest is required.") }
    let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    try validateManifest(manifest)
    for frame in manifest.frames {
        let status = fileManager.fileExists(atPath: captureURL(frame, manifestURL: manifestURL).path) ? "present" : "PENDING CAPTURE"
        print("\(frame.id): headline \(frame.headline.count) chars, subline \(frame.subline.count) chars · \(status)")
    }
    if mode == "validate" {
        print("Manifest valid. Capture pixels are checked by --check-captures or --output.")
        exit(0)
    }
    // Preflight all captures before creating any finished frame.
    let captures = try manifest.frames.map { try readCapture($0, manifestURL: manifestURL) }
    for capture in captures {
        print("\(capture.frame.id): \(capture.image.width)×\(capture.image.height), scale \(String(format: "%.3f", capture.scale)), calculation text ≥\(String(format: "%.1f", capture.frame.sourceTextSizePx * capture.scale)) px (declared)")
    }
    if mode == "check" { print("All captures passed resolution and declared legibility checks."); exit(0) }
    guard let outputPath else { try fail("--output is required for rendering.") }
    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    guard !captures.contains(where: { $0.url.deletingLastPathComponent() == outputURL }),
          outputURL != manifestURL.deletingLastPathComponent() else {
        try fail("Use a separate finished output directory; never overwrite the raw captures or source manifest.")
    }
    try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
    var images: [(String, CGImage)] = []
    var records: [[String: Any]] = []
    for capture in captures {
        let image = try render(capture, style: manifest.style)
        let filename = "\(capture.frame.id).png"
        try writePNG(image, to: outputURL.appendingPathComponent(filename))
        images.append((capture.frame.id, image))
        records.append(["id": capture.frame.id, "file": filename, "rawCapture": capture.url.path,
                        "rawSHA256": try sha256(capture.url),
                        "outputSHA256": try sha256(outputURL.appendingPathComponent(filename)),
                        "rawWidth": capture.image.width, "rawHeight": capture.image.height,
                        "scale": capture.scale, "declaredOutputTextPx": capture.frame.sourceTextSizePx * capture.scale,
                        "outputWidth": canvasWidth, "outputHeight": canvasHeight,
                        "colorSpace": "sRGB", "alpha": false])
    }
    let contact = try contactSheet(images, background: color(manifest.style.background), ink: color(manifest.style.ink))
    try writePNG(contact, to: outputURL.appendingPathComponent("contact-sheet-review-only.png"))
    let report: [String: Any] = ["schemaVersion": 1, "manifest": manifestURL.path,
                              "manifestSHA256": try sha256(manifestURL),
                              "note": "Contact sheet is review-only. Visually verify authenticity, exact results, and thumbnail readability before upload.",
                              "frames": records]
    let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try reportData.write(to: outputURL.appendingPathComponent("build-report.json"), options: .atomic)
    print("Rendered \(images.count) upload frames to \(outputURL.path). Inspect the review-only contact sheet before upload.")
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
