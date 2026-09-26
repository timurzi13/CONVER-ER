<div align="center">

<img src="docs/icon.png" width="112" alt="">

# CONVER+ER

**Batch image, PDF and video converter for macOS.**<br>
Drop files in, pick a format, press Start.

[![Download](https://img.shields.io/badge/Download-macOS%20·%20Universal-000000?style=for-the-badge)](https://github.com/timurzi13/CONVER-ER/releases/latest/download/CONVER-ER-macos.zip)

![macOS 15+](https://img.shields.io/badge/macOS-15+-555?style=flat-square)
![Universal](https://img.shields.io/badge/Apple_Silicon_+_Intel-555?style=flat-square)
![Self-contained](https://img.shields.io/badge/nothing_to_install-555?style=flat-square)
[![MIT](https://img.shields.io/badge/license-MIT-555?style=flat-square)](LICENSE)

[Русский](README.ru.md)

</div>

![CONVER+ER](docs/screenshot.png)

---

## What it does

It was built for one job — **JP2 → PNG** — and then grew to cover everything else
Apple's imaging stack can handle, plus PDF, plus video. A switch above the settings
flips between the two halves; each keeps its own queue and its own settings.

### Images

**Reads** JPEG 2000 · PDF · PNG · JPEG · TIFF · HEIC · AVIF · WebP · PSD · GIF · BMP ·
OpenEXR · DICOM · camera RAW from Canon, Nikon, Sony, Fuji, Leica, Phase One and the
rest — 60-odd formats in all.

**Writes** PNG · JPEG · TIFF · HEIC · AVIF · JPEG 2000 · BMP · GIF · PSD · OpenEXR · PDF

### Video

**Reads** MOV · MP4 · M4V · AVI · MPEG · MPEG-2 TS · DV · 3GP through macOS itself, and
**MKV · WebM · FLV · WMV · Ogg · RealMedia · MXF** plus the QuickTime-era codecs Apple
dropped — Sorenson, Cinepak, Indeo, Apple Video — through a bundled FFmpeg.

**Writes** MOV · MP4 · M4V, as H.264, HEVC, ProRes 422 or ProRes 4444 — or as a
**straight copy** that rewraps the streams into the new container without re-encoding
anything. MOV → MP4 that way takes a second and loses nothing.

![Video](docs/screenshot-video.png)

Drop files or whole folders (they unfold recursively), drop them on the Dock icon, or
use `⌘O`. Images and videos sort themselves into their tabs; drop only videos and the
app switches to Video for you. Stills convert in parallel across all cores, video two at
a time so the hardware encoders stay busy without fighting each other.

## Install

1. **[Download the latest release](https://github.com/timurzi13/CONVER-ER/releases/latest)**
2. Unzip and move `CONVER+ER.app` to your Applications folder
3. Clear the quarantine flag once — see below

### macOS will block it on first launch

The app is signed ad-hoc rather than with a paid Apple Developer ID, so macOS treats it
as unidentified. One command fixes it for good:

```bash
xattr -dr com.apple.quarantine /Applications/CONVER+ER.app
```

Or open it once, then go to **System Settings → Privacy & Security**, scroll down and
press **Open Anyway**.

## Settings

The panel only shows what actually affects the format you picked — no dead controls.

**Images**

| | |
|---|---|
| **Format** | the output format |
| **Quality** | lossy formats only (JPEG, HEIC, AVIF, JP2) |
| **Full / Scale / Fit** | 1:1, a percentage, or fit to the longest side |
| **Flatten Onto** | the colour transparent pixels land on, for formats that can't store alpha |
| **Keep Metadata** | carry EXIF / IPTC / colour profile into the result |
| **Pages** | every page of a PDF, or one specific page |
| **Raster DPI** | how finely a PDF page is rendered — 72 is the page's own size |

**Video**

| | |
|---|---|
| **Format** | MOV, MP4 or M4V |
| **Codec** | Copy Streams, H.264, HEVC — plus ProRes 422 and 4444 in MOV |
| **Max Size** | a ceiling for H.264 and HEVC; smaller clips keep their own size |
| **Keep Audio** | off gives you a silent clip, handy for loops |

**Both**

| | |
|---|---|
| **Save To** | beside the original, or into a folder you choose |
| **If Exists** | rename, overwrite, or skip |

<img src="docs/screenshot-empty.png" alt="">

## Under the hood

Everything runs on Apple's **ImageIO**, **CoreGraphics** and **AVFoundation** — JPEG 2000
support and hardware video encoders are already in macOS, they just aren't exposed
anywhere useful. Nothing to install: no Homebrew, no Python, no command line.

The one thing macOS can't do is read video it has given up on. For that the app carries
a small **FFmpeg** of its own, built LGPL-only, static and universal. It only steps in when
macOS can't open or decode a file — the queue says *via FFmpeg* when it does — and even
then the encoding goes through the same Apple hardware (VideoToolbox), with FFmpeg's own
ProRes and AAC encoders for the rest.

Three things the converter is careful about:

- **No needless re-encoding.** At 1:1, with no alpha to flatten and no EXIF rotation to
  apply, the decoded image goes straight to the file. 16-bit stays 16-bit and greyscale
  stays greyscale, so an archival JP2 scan doesn't triple in size by being inflated to RGB.
- **Rotation is baked into the pixels.** PNG has nowhere to store an EXIF orientation tag,
  so anything with orientation ≠ 1 is redrawn. The result was checked pixel-for-pixel
  against ImageIO's own transform.
- **PDF pages really scale.** `CGPDFPageGetDrawingTransform` only ever shrinks a page to
  fit and never enlarges it, so the scale is applied explicitly. 600 dpi gives you a real
  600 dpi raster, not a 72 dpi page floating on a large white sheet.

PDF → PDF is a page extract rather than a re-render: the vectors survive.

On the video side:

- **Copy Streams re-encodes nothing.** Switching container is a rewrap, so it's instant
  and bit-identical.
- **Portrait phone clips stay upright.** A phone records landscape and marks the file as
  rotated; that rotation is carried across every path, including the silent one, which
  has to rebuild the clip from its picture track alone.
- **Impossible combinations never reach the encoder.** ProRes only exists in MOV, so the
  codec list simply doesn't offer it for MP4 and M4V, and size presets appear only where
  the system actually has them.

## Build it yourself

No Xcode project, no package manager, no dependencies — just the Command Line Tools:

```bash
xcode-select --install
./build.sh
```

That produces a universal (Apple Silicon + Intel) `build/CONVER+ER.app`.

To include FFmpeg, build it first — it downloads the pinned source from ffmpeg.org,
checks its SHA-256 and compiles both architectures (a few minutes, once):

```bash
./scripts/build-ffmpeg.sh
./build.sh
```

Without that step the app still builds and runs; it just can't open the formats above.

```
Sources/
  App.swift         window, menus, the settings column
  Shell.swift       header, footer, panel, floating bars
  Controls.swift    slider, toggle, select, pills, swatch
  ScrollArea.swift  the custom scrollbar
  Stage.swift       drop zone, queue, bottom bars
  Model.swift       state, queue, the parallel run
  Converter.swift   the image and PDF engine
  VideoConverter.swift  the video engine
  FFmpeg.swift      the bridge to the bundled ffmpeg
scripts/
  build-ffmpeg.sh   the exact FFmpeg build that ships
  Theme.swift       palette, metrics, type
```

## Credits

Typeface: [DM Sans](https://fonts.google.com/specimen/DM+Sans), SIL Open Font License.

Video the system can't read: [FFmpeg](https://ffmpeg.org), LGPL 2.1 or later. It runs as a
separate program inside the app (`Contents/Helpers/ffmpeg`) and can be swapped for any
other build; the licence, version and build flags travel with it in
`Contents/Resources/ThirdParty/FFmpeg`.

Created by **[[BUR0U3]+](https://www.instagram.com/burou3_/)**

MIT licensed — see [LICENSE](LICENSE).
