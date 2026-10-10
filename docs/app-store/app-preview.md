# Mac App Preview: 24-second storyboard and production pipeline

The preview demonstrates real Vektor use. It is **1920×1080 landscape, 24 seconds, 30 fps**, separate from the 2880×1800 screenshot masters. It should make sense during muted autoplay. The footage uses an active trial or lifetime unlock. Include a readable “60-day free trial; one-time purchase for continued access” overlay so featured tools are not presented as permanently free. Do not show a specific price, unsupported global shortcut, filmed hardware or animated imitation of the app.

Apple's current Mac preview format is 16:9 while Mac screenshots are 16:10, so the preview can appear in **A Closer Look** rather than the main screenshot gallery. The first screenshot therefore remains the primary conversion asset. [Apple preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/), [App Preview guidance](https://developer.apple.com/app-store/app-previews/), [Review Guidelines 2.3.4](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).

## Storyboard

All times refer to the final timeline, not raw take duration. Use direct cuts and real-time app interactions; allow the evaluation to finish before the hold. A caption can sit in an unused strip of the app canvas without covering inputs or answers. Use short white/cream text with a dark backing where needed, sized approximately 48–56 px at 1080p. No caption-only intro or end card. Keep every input and result readable at reduced size. The trial/purchase disclosure can use a separate unobstructed lower caption, visible during the opening and final holds.

| Time | Screen / exact action | Overlay | End-of-shot proof |
| --- | --- | --- | --- |
| 0.0–3.0 s | Calculator, Project estimate body from screenshot 1. Begin with the last line `subtotal + ta`; type the final `x`, wait for evaluation, hold. | Write the math. See the answer. | The real 1 224.00 result beside its expression, with the named inputs visible |
| 3.0–7.0 s | Cut to Weekend budget, initially `guests = 4`. Select only the `4`, replace with `6`, wait, hold. Other lines match screenshot 5. | Change an input. Results follow. | Cost per guest changes from 54.00 to 36.00 |
| 7.0–11.0 s | Quick conversions body from screenshot 2 with first three conversions complete. Type `15% off 240` as the fourth expression, wait, hold. | Convert as you type. | 204.00 and the other real unit results |
| 11.0–15.0 s | On Weekend budget, click its pin if needed, then SHEET header. Show real pinned Project estimate, Quick conversions and Weekend budget. Click Project estimate; close popover via the selection. | Keep useful sheets close. | Selection returns to the saved estimate |
| 15.0–20.0 s | One real recording region containing Vektor's panel and actual macOS menu-bar icon. Click the icon to hide the panel, then click it again to show the same sheet. Do not simulate a global keystroke. | A click away in your menu bar. | Same work reappears, no fabricated icon or composite desktop |
| 20.0–24.0 s | Hold the real Project estimate panel; bring the cursor to neutral unused canvas space. | Keep the thought and the math together. | Useful calculation remains visible through the final frame |

**Poster:** select an actual frame around **2.5 seconds**, after 1 224.00 appears and the first caption is visible. Apple's default is 5 seconds; explicitly select this stronger footage frame in Connect. Confirm the selected time against the exported video, since edit changes move it.

The video stays deterministic. Currency and weather are in later screenshots, where data freshness and provider readiness can be inspected. Do not stage a pre-populated rate as if the app fetched it instantly.

## Record real footage

1. Use a dedicated macOS capture account and the current `Vektor` build. Record the source commit, macOS version, app version, logical window size and backing scale. Do not reset an existing user's UserDefaults, purchase state, Keychain or documents. Use the exact sheets in [product-page.md](product-page.md).
2. Set the capture account's app appearance to light, precision to 2 and digit grouping on. Disable recording microphone/system audio; the finished exporter replaces source audio with stereo silence. Use a clean desktop containing only Vektor and macOS chrome, with no private notifications, third-party app content or unrelated branding in the capture region.
3. For panel-only shots, target a **960×540 logical-point capture region on a 2× display**, yielding native 1920×1080 pixels; inspect the actual panel frame to ensure it fits. The minimum content size is 760×520 points. For the menu-bar shot, use a larger genuine **1120×630-point region** (2240×1260 pixels at 2×), position the panel under its real icon, and scale the complete region uniformly to 1920×1080 in the editor. The larger region accommodates panel chrome and the real menu-bar strip; 960×540 is too tight for both. Do not stretch a 16:10 desktop into 16:9. If your recorder emits logical pixels rather than backing pixels, inspect the output and choose a larger native region. The recorded file, not the screen setting, determines compliance.
4. Use macOS Screenshot toolbar (⇧⌘5 → Record Selected Portion), QuickTime screen recording, or ScreenCaptureKit-based capture. Make separate longer takes for each interaction, with two seconds of still handles before/after. Measure captured dimensions with `ffprobe` before editing. macOS permission prompts, storage UI and desktop preparation stay outside the recorded footage.
5. Edit in a **1920×1080, 30 fps SDR** timeline in your editor (for example iMovie's App Preview project or Final Cut Pro). Cut only to actual captures; preserve the UI aspect ratio. Screen recordings may be variable frame rate; the final exporter normalizes to constant 30 fps. Keep the final timeline 24 seconds. Any crop must preserve the inputs and answers needed to understand the feature; do not hide important status or conditions.
6. Export the edited timeline at 1920×1080 (ProRes master or high-quality H.264). Treat it as `artifacts/app-store/video/edited-master.mov`. Titles/overlays are baked into this master; the script is an encoder and validator, not a video editor. If using music or narration instead of silence, obtain rights and use a deliberate alternate audio workflow that meets Apple's specs. The provided exporter intentionally uses silence.

## Encode and inspect

The script requires **ffmpeg and ffprobe**, including the `libx264` encoder. They are not installed on the task host at the time of this package's verification. Obtain ffmpeg through your trusted tooling (for example Homebrew); no package installation is performed by this kit. Python 3 is required. The metadata and screenshot tools work without ffmpeg.

```sh
python3 scripts/app-store/validate-preview.py --source artifacts/app-store/video/edited-master.mov
python3 scripts/app-store/export-preview.py artifacts/app-store/video/edited-master.mov artifacts/app-store/video/vektor-preview-1080p.mp4
python3 scripts/app-store/validate-preview.py artifacts/app-store/video/vektor-preview-1080p.mp4
```

The export uses H.264 High Profile Level 4.0, progressive 8-bit 4:2:0, square pixels, constant 30 fps, 11 Mbps target with 12 Mbps maxrate, BT.709 SDR tags, a single stereo AAC track at 48 kHz / 256 kbps encoder setting, and MP4 fast-start. It strips inherited metadata/extra tracks and refuses an existing output path. Input must already be 1920×1080, progressive, square-pixel SDR BT.709 and 15–30 seconds; it will not silently resize, distort or tone-map a wrong source. Known non-BT.709/HDR tags fail preflight; missing color tags require manual review. Actual average bitrates may be lower for static UI or silence; the checker flags them for review rather than pretending a target is a mandatory measured bitrate. Encoder behavior is documented by [FFmpeg](https://ffmpeg.org/ffmpeg.html#Advanced-options), [libx264 options](https://ffmpeg.org/ffmpeg-codecs.html#libx264_002c-libx264rgb), and the [silent audio source](https://ffmpeg.org/ffmpeg-filters.html#anullsrc).

Apple permits MOV/M4V/MP4 H.264 and a ProRes 422 HQ MOV alternative. This kit chooses one conservative H.264 profile. The local checker verifies geometry, duration, size ≤500,000,000 bytes, codec/profile/level, progressive pixels, square pixels, average and nominal rate, track count, audio channels/sample rate and approximate audio/video alignment. It cannot prove every frame is CFR from stream metadata, inspect all enabled-track flags or external references, establish content rights, or guarantee App Review/Connect acceptance.

Watch the encoded MP4 from first frame to last, both silent and at normal volume. Check caption legibility, UI sharpness, typing cadence, cut continuity, color, absence of notifications and unexpected audio, and that the first answer actually appears before the hold. Inspect a poster candidate:

```sh
ffmpeg -n -ss 2.5 -i artifacts/app-store/video/vektor-preview-1080p.mp4 -frames:v 1 artifacts/app-store/video/poster-review.png
```

The PNG is a local review aid; select a frame from the uploaded video in Connect. Upload the preview in the correct Mac localization, wait for processing (Apple says it may take up to 24 hours), inspect Connect's rendition and poster, and resolve any server-side rejection. Local validation is a production check, not a guarantee of approval. Keep the source master, exported file, probe output and source-commit note together for repeatability.
