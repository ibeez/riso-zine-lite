# riso-zine-lite

A lightweight, zero-dependency toolkit for building **continuous multi-panel digital-Riso zine scrolls** in plain HTML/SVG, with a native macOS **razor-blade subject cutout CLI** and one-click **2× Retina PNG export** right in the browser.

## What's Inside

- **`lib/riso-zine.js`** — Standalone SVG Riso engine:
  - Warm cream paper (`#fbf5e6`), fractal grain, and 4 multiply-overprint inks (`coral`, `blue`, `peach`, `sky`)
  - `m.photo(...)` for 0° editorial photo blocks with offset halftone backing
  - `m.cutout(...)` for transparent PNGs with **exact-silhouette Riso offset shadows** (`backK`) and optional opaque paper silhouette knockouts (`lift: true`)
  - `m.inkFilter(...)` for panel-scoped woodblock/Riso ink-edge wobble & ink-starvation grain (safe across translated multi-panel seams)
  - `RisoZine.downloadPNG(...)` and `RisoZine.downloadScrollPNG(...)` to export individual panels or one stitched wide scroll directly from the browser
- **`tools/cutout.m`** — Native macOS (14+) subject cutout CLI built on Apple's Vision framework (`VNGenerateForegroundInstanceMaskRequest`) + Ramer–Douglas–Peucker polygon slicing:
  - Zero Python packages, zero model downloads, runs on the Neural Engine
  - Default mode slices subjects with **sharp X-Acto / razor-blade faceted edges** (no soft AI halo)
  - `--paper` mode knocks out bright paper backgrounds on vintage engravings and line drawings
- **`examples/two-panel-demo.html`** — Ready-to-open 2-panel (`1680×1120`) continuous scroll starter with coordinate HUD, toggleable grid (`G`), and one-click PNG / full-scroll export buttons.

## Quick Start

### 1. Preview & export the 2-panel demo

Open `examples/two-panel-demo.html` in Chrome (or serve locally with `python3 -m http.server` when using external image cutouts):

```bash
open -a "Google Chrome" examples/two-panel-demo.html
```

Press **`G`** to toggle the alignment grid, hover any panel to inspect `(x, y)` coordinates, and click **Export Panels** or **Export Full Scroll** to download 2× Retina PNGs straight from the browser.

### 2. Build & use the razor-blade cutout tool (macOS 14+)

```bash
make
```

```bash
# Lift a subject from a photo with sharp razor-blade faceted edges
./tools/cutout photo.jpg

# Tune facet chunkiness (px) or keep smooth Vision edges
./tools/cutout --facets 10 statue.jpg statue-cutout.png
./tools/cutout --soft portrait.jpg

# Batch-process an entire folder
./tools/cutout --dir ./cutouts

# Knock out bright paper backgrounds on vintage engravings / diagrams
./tools/cutout --paper --threshold 0.86 engraving.jpg
```

## License

MIT
