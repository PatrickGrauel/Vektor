# Screenshot production

The committed source is `screenshots.json` plus the native composer in `scripts/app-store`. The composer reads real app captures and adds the listing headline and subline. It preserves the entire supplied capture and its aspect ratio; it does not recreate controls, paste calculated answers into the UI, or manufacture a menu bar.

Production files belong under `artifacts/app-store/raw/` and `artifacts/app-store/finished/`. Keep those directories ignored in Git: raw captures can contain personal information and every finished set can be rebuilt. Commit the manifest, copy, and tools. Final upload images are the ordered `01-….png` through `06-….png`; the contact sheet and build report are for review only.

## Requirements and commands

Use macOS with Xcode Command Line Tools installed. The compositor uses Swift, AppKit, Core Graphics, and ImageIO already supplied by macOS. It needs no package install or network connection. It compiles into a task-specific temporary directory and never writes to Vektor's preferences or document storage.

From the repository root:

```sh
# Copy/layout validation succeeds while the real captures are still pending.
scripts/app-store/render.sh --manifest docs/app-store/screenshots.json --validate

# After every raw capture exists: strict resolution and scaling preflight.
scripts/app-store/render.sh --manifest docs/app-store/screenshots.json --check-captures

# Compose the full ordered set, contact sheet, and machine-readable report.
scripts/app-store/render.sh --manifest docs/app-store/screenshots.json \
  --output artifacts/app-store/finished

# Integration tests create synthetic verification grids in temporary storage.
# These are deliberately labeled, never app screenshots, and never uploadable.
python3 scripts/app-store/test-renderer.py

# Text limits, indexed word duplication, first-release notes and preview checks.
python3 scripts/app-store/test-metadata-preview.py

# Validate/generate pasteable Connect copy from the canonical JSON.
python3 scripts/app-store/validate-metadata.py --check-listing docs/app-store-listing.md
python3 scripts/app-store/validate-metadata.py --export-dir artifacts/app-store/metadata
```

Every upload frame is exactly **2880×1800**, 16:10, 8-bit RGB, sRGB, PNG, with **no alpha**. ImageIO reopens each generated file to verify dimensions, RGB color space, and the absence of alpha. Raw window captures may have transparent corners; the compositor flattens them onto the opaque canvas. `build-report.json` records the manifest, each raw file, and each output file's SHA-256 hash alongside its dimensions and render scale, so the reviewed set can be identified exactly.

The layout uses Vektor's actual cream `#F7F4EE`, navy `#0E1521`, muted ink `#7C766A`, and burnt orange `#C2611F`. It uses the native system font: 96 px headline, 42 px subline, a small 34 px Vektor wordmark, and a restrained window shadow. The screenshot fits inside a 2580×1190 px area beginning at `(150,490)` on the final canvas. No cropping, distortion, rounded-corner mask, or artificial window chrome is applied.

## Safe, repeatable raw captures

Use a separate **macOS capture account** with the same release build intended for submission. This keeps the user's existing notes, preferences, API keys, and window geometry intact. Do not reset their preferences, replace `vektor.documents.v1`, or overwrite an existing note. If a separate account is unavailable, add a fresh screenshot document with **⌘N** and leave existing documents untouched; record any appearance or panel-size changes so they can be restored.

1. Launch the exact release candidate. Record its version/build, macOS version, capture date, appearance, logical window dimensions, and screen scale in your capture log. Wait until launch work completes.
2. Use a Retina display at its actual 2× pixel scale. Resize the app's real panel to approximately **1280×600 points**; this produces approximately **2560×1200 pixels**. The app supports this size: its minimum panel content size is 760×520 points. Check the actual pixel dimensions of the saved image instead of assuming the display's scale.
3. Use the appearance stated for each frame in `screenshots.json`. Vektor's calculator uses fixed `NSFont.systemFontSize` monospaced type; there is no font-size control. Do not invent a zoom setting or enlarge text in an image editor.
4. Create a fresh note, paste `typedContent` exactly, and follow `captureNotes`. Let live conversions finish; make sure every intended result is visible and there are no error, loading, stale-data, or credential messages. Network-fed results must be actual values from that capture session.
5. Move the pointer away from the important text. Capture the actual app window without its macOS drop shadow:

   ```sh
   scripts/app-store/capture.sh artifacts/app-store/raw/01-project-estimate.png
   ```

   Click the Vektor window in macOS's native selection UI. This command uses `screencapture -i -W -o -t png`, and refuses to overwrite an existing capture. Press Escape to cancel. It does not type, change notes, toggle settings, or resize the app.

6. Repeat using each manifest filename. `capture` paths are resolved relative to `docs/app-store/screenshots.json`, so `../../artifacts/app-store/raw/01-project-estimate.png` selects the repository's raw directory. **Frame 4 includes a sheets popover:** use `scripts/app-store/capture.sh --region --delay 5 artifacts/app-store/raw/04-saved-sheets.png`. During the five-second setup delay, refocus Vektor and reopen the SHEET popover; then drag around the real panel and popover together. Launching a capture from foreground Terminal can otherwise dismiss the popover, and a single-window capture may omit it. Leave `captureKind` as `window` when the region shows the app and its transient UI; use `desktop` when it includes wider desktop/menu-bar context.
7. Run `--check-captures`, render, then inspect the full-size frames and the contact sheet. Keep the untouched raw files so recaptures and copy revisions remain traceable.

For a menu-bar context shot, capture a **real desktop region** containing the menu bar and app, with no private or unrelated material. `scripts/app-store/capture.sh --region PATH` uses macOS's mouse-selection mode (`screencapture -i -s -t png`) for this region. Set `captureKind` to `desktop` in the manifest and measure its actual text size. Keep a similar wide, short aspect ratio. A full 2880×1800 desktop shrunk into the poster layout makes the current 26 px raw calculator type about 17 px tall; the quality preflight correctly rejects that. Never paste a status icon or fabricated menu bar into a window capture. The current six-frame production plan uses app-window captures; a menu-bar context shot is an optional replacement requiring a real recapture and a corresponding manifest update.

## Manifest and quality gates

Each frame supplies an ordered ID, one-line headline and subline, local capture path, `captureKind` (`window` or `desktop`), actual appearance, minimum raw dimensions, `sourceTextSizePx`, exact `typedContent`, and capture notes. Extra documentation fields are permitted. The canvas and style fields are shared across the set.

`sourceTextSizePx` is the nominal size of the primary calculation text **in the raw image**, not the app's point size. With the current 13 pt editor font captured at 2×, use **26**. At 2560×1200 px the render scale is approximately 0.992, preserving calculation text at about **25.8 px**. Confirm the actual system font and backing scale on the capture Mac; this value is a declared measurement, not optical character recognition.

The strict preflight rejects missing or unreadable files, invalid image orientation, images below the declared minimum, excessive image dimensions, required enlargement, unordered or duplicate IDs, mock capture kinds, overflowing headline/subline copy, and primary calculation type below **24 px after scaling**. It preflights every raw capture before writing any final frame. It also prevents output into the raw directory or the manifest directory.

The 24 px threshold is this project's production heuristic, **not an Apple specification**. Automated checks cannot prove that supplied pixels came from Vektor, measure actual glyph readability, detect every blur or personal detail, or verify network results. Before upload, review these points manually:

- The actual app UI and calculated results match the submitted build and exact typed content.
- Both full-size and thumbnail views are readable, especially variable results and conversion units.
- Complete app chrome and important results are visible, with no cursor covering them or unintended selection.
- Colors and window edges are clean; raw captures were never stretched or enlarged.
- Names, notes, notifications, personal information, third-party branding, and API keys are absent.
- Only the ordered 2880×1800 frames are uploaded. `contact-sheet-review-only.png`, `build-report.json`, raw files, and synthetic test fixtures stay out of App Store Connect.

See [apple-specs.md](apple-specs.md) for the dated, verified Apple requirements and [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) for the official source. Recheck those sources before submission; accepted sizes and media rules can change.

## Verification performed for this package

Seven native renderer/capture integration tests and fifteen metadata/preview validation tests passed. The renderer was exercised with temporary RGBA strip fixtures explicitly labeled **SYNTHETIC VERIFICATION ONLY**, then its PNG output was visually inspected. Tests confirmed 2880×1800 opaque RGB output, input/output hashes, no partial set on missing captures, and rejection of inadequate size/readability, bad copy, ordering and overwrite attempts. The actual six-frame production manifest passed copy/layout validation; its genuine captures are pending.

The deterministic screenshot expressions were also evaluated against the current calculator engine at precision 2; results are recorded in [code-audit.md](code-audit.md). Preview tests exercise probe-data boundaries, including wrong geometry, HDR/interlaced sources, excessive frame rates, short video masked by longer audio, and mismatched audio duration. They do not encode a video: ffmpeg/ffprobe are absent from the task host. The [preview pipeline](app-preview.md) documents that dependency and the remaining visual/Connect checks.
