<div align="center">

<img src="docs/icon.png" width="112" alt="">

# CONVER+ER

**Пакетный конвертер изображений и PDF для macOS.**<br>
Бросил файлы, выбрал формат, нажал Start.

[![Скачать](https://img.shields.io/badge/Скачать-macOS%20·%20Universal-000000?style=for-the-badge)](https://github.com/timurzi13/CONVER-ER/releases/latest/download/CONVER-ER-1.0-macos.zip)

![macOS 15+](https://img.shields.io/badge/macOS-15+-555?style=flat-square)
![Universal](https://img.shields.io/badge/Apple_Silicon_+_Intel-555?style=flat-square)
![Без зависимостей](https://img.shields.io/badge/зависимости-нет-555?style=flat-square)
[![MIT](https://img.shields.io/badge/лицензия-MIT-555?style=flat-square)](LICENSE)

[English](README.md)

</div>

![CONVER+ER](docs/screenshot.png)

---

## Что умеет

Делался под одну задачу — **JP2 → PNG**, — а потом дорос до всего остального, что умеет
графический стек macOS, плюс PDF.

**Читает** JPEG 2000 · PDF · PNG · JPEG · TIFF · HEIC · AVIF · WebP · PSD · GIF · BMP ·
OpenEXR · DICOM · RAW с Canon, Nikon, Sony, Fuji, Leica, Phase One и прочих — шестьдесят
с лишним форматов.

**Пишет** PNG · JPEG · TIFF · HEIC · AVIF · JPEG 2000 · BMP · GIF · PSD · OpenEXR · PDF

Кидайте файлы или целые папки (разворачиваются рекурсивно), можно на иконку в Dock или
через `⌘O`. Конвертация идёт параллельно по всем ядрам.

## Установка

1. **[Скачать последнюю версию](https://github.com/timurzi13/CONVER-ER/releases/latest)**
2. Распаковать и перетащить `CONVER+ER.app` в папку «Программы»
3. Один раз снять карантин — см. ниже

### При первом запуске macOS его не пустит

Приложение подписано ad-hoc, а не платным Apple Developer ID, поэтому система считает его
неопознанным. Лечится одной командой, навсегда:

```bash
xattr -dr com.apple.quarantine /Applications/CONVER+ER.app
```

Либо попробовать открыть, а потом зайти в **Системные настройки → Конфиденциальность и
безопасность**, пролистать вниз и нажать **Всё равно открыть**.

## Настройки

Панель показывает только то, что реально влияет на выбранный формат, — мёртвых контролов нет.

| | |
|---|---|
| **Format** | формат на выходе |
| **Quality** | только форматы с потерями (JPEG, HEIC, AVIF, JP2) |
| **Full / Scale / Fit** | 1:1, в процентах, или вписать по длинной стороне |
| **Flatten Onto** | цвет, на который лягут прозрачные пиксели, если формат не держит альфу |
| **Keep Metadata** | перенести EXIF / IPTC / цветовой профиль в результат |
| **Pages** | все страницы PDF или одна конкретная |
| **Raster DPI** | с каким разрешением растрить страницу PDF, 72 — размер страницы 1:1 |
| **Save To** | рядом с оригиналом или в выбранную папку |
| **If Exists** | переименовать, перезаписать или пропустить |

<img src="docs/screenshot-empty.png" alt="">

## Что внутри

Всё работает на **ImageIO** и **CoreGraphics**. Никаких сторонних декодеров, Homebrew и
Python — поддержка JPEG 2000 в macOS давно есть, её просто нигде не дают в руки.

Три вещи, на которые движок обращает внимание:

- **Без лишнего перекодирования.** При 1:1, когда нечего сводить по альфе и нет
  EXIF-поворота, распакованная картинка уходит в файл как есть. 16 бит остаются 16 битами,
  серый остаётся серым — архивный скан в JP2 не раздувается втрое, превращаясь в RGB.
- **Поворот запекается в пиксели.** PNG негде хранить EXIF-ориентацию, поэтому всё с
  orientation ≠ 1 перерисовывается. Результат сверен попиксельно с тем, как поворачивает
  сам ImageIO.
- **Страницы PDF действительно масштабируются.** `CGPDFPageGetDrawingTransform` умеет
  только вписывать с уменьшением и никогда не увеличивает, поэтому масштаб задаётся явно.
  600 dpi — это настоящие 600 dpi, а не страница в 72 dpi на большом белом листе.

PDF → PDF — это вырезание страницы, а не перерендер: вектор остаётся вектором.

## Собрать самому

Ни Xcode-проекта, ни пакетного менеджера, ни зависимостей — только Command Line Tools:

```bash
xcode-select --install
./build.sh
```

На выходе универсальный (Apple Silicon + Intel) `build/CONVER+ER.app`.

```
Sources/
  App.swift         окно, меню, левая колонка настроек
  Shell.swift       хедер, футер, панель, плавающие плашки
  Controls.swift    слайдер, тоггл, селект, пилюли, свотч
  ScrollArea.swift  свой скроллбар
  Stage.swift       дропзона, очередь, нижние плашки
  Model.swift       состояние, очередь, параллельный прогон
  Converter.swift   движок
  Theme.swift       палитра, метрики, типографика
```

## Благодарности

Шрифт: [DM Sans](https://fonts.google.com/specimen/DM+Sans), SIL Open Font License.

Сделал **[[BUR0U3]+](https://www.instagram.com/burou3_/)**

Лицензия MIT — см. [LICENSE](LICENSE).
