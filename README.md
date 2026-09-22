<div align="center">

<img src="docs/icon.png" width="112" alt="">

# CONVER+ER

**Batch image and PDF converter for macOS.**<br>
Drop files in, pick a format, press Start.

[![Download](https://img.shields.io/badge/Download-macOS%20·%20Universal-000000?style=for-the-badge)](https://github.com/timurzi13/CONVER-ER/releases/latest/download/CONVER-ER-1.0-macos.zip)

![macOS 15+](https://img.shields.io/badge/macOS-15+-555?style=flat-square)
![Universal](https://img.shields.io/badge/Apple_Silicon_+_Intel-555?style=flat-square)
![No dependencies](https://img.shields.io/badge/dependencies-none-555?style=flat-square)
[![MIT](https://img.shields.io/badge/license-MIT-555?style=flat-square)](LICENSE)

[Русский](README.ru.md)

</div>

![CONVER+ER](docs/screenshot.png)

---

## What it does

It was built for one job — **JP2 → PNG** — and then grew to cover everything else
Apple's imaging stack can handle, plus PDF.

**Reads** JPEG 2000 · PDF · PNG · JPEG · TIFF · HEIC · AVIF · WebP · PSD · GIF · BMP ·
OpenEXR · DICOM · camera RAW from Canon, Nikon, Sony, Fuji, Leica, Phase One and the
rest — 60-odd formats in all.

**Writes** PNG · JPEG · TIFF · HEIC · AVIF · JPEG 2000 · BMP · GIF · PSD · OpenEXR · PDF

Drop files or whole folders (they unfold recursively), drop them on the Dock icon, or
use `⌘O`. Everything converts in parallel across your cores.

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

| | |
|---|---|
| **Format** | the output format |
| **Quality** | lossy formats only (JPEG, HEIC, AVIF, JP2) |
| **Full / Scale / Fit** | 1:1, a percentage, or fit to the longest side |
| **Flatten Onto** | the colour transparent pixels land on, for formats that can't store alpha |
| **Keep Metadata** | carry EXIF / IPTC / colour profile into the result |
| **Pages** | every page of a PDF, or one specific page |
| **Raster DPI** | how finely a PDF page is rendered — 72 is the page's own size |
| **Save To** | beside the original, or into a folder you choose |
| **If Exists** | rename, overwrite, or skip |

<img src="docs/screenshot-empty.png" alt="">

## Under the hood

Everything runs on Apple's **ImageIO** and **CoreGraphics**. No bundled decoders, no
Homebrew, no Python — JPEG 2000 support is already in macOS, it just isn't exposed
anywhere useful.

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

## Build it yourself

No Xcode project, no package manager, no dependencies — just the Command Line Tools:

```bash
xcode-select --install
./build.sh
```

That produces a universal (Apple Silicon + Intel) `build/CONVER+ER.app`.

```
Sources/
  App.swift         window, menus, the settings column
  Shell.swift       header, footer, panel, floating bars
  Controls.swift    slider, toggle, select, pills, swatch
  ScrollArea.swift  the custom scrollbar
  Stage.swift       drop zone, queue, bottom bars
  Model.swift       state, queue, the parallel run
  Converter.swift   the engine
  Theme.swift       palette, metrics, type
```

## Credits

Typeface: [DM Sans](https://fonts.google.com/specimen/DM+Sans), SIL Open Font License.

Created by **[[BUR0U3]+](https://www.instagram.com/burou3_/)**

MIT licensed — see [LICENSE](LICENSE).
