# CRT-Standalone — Changelog

## Current Version

### New Features

#### Dual-Scale Bloom
A second, wider glow pass running at quarter resolution adds a broad soft halo over large bright areas (sky, windows, surfaces), complementing the tight per-element glow. Three new controls under Brightness & Glow: Wide Glow Strength (default 0.0 = off), Wide Glow Radius, Wide Glow Threshold. Very cheap — two additional passes at quarter resolution.

#### Spectral Bloom
Physically based chromatic glow: blue light diffracts more than red through a lens aperture. The blue channel of the glow now blooms slightly wider than red (R=0.75×, G=1.0×, B=1.35× sigma) when Spectral Bloom > 0. Based on wavelength-dependent diffraction physics. Default 0.0 (uniform, original behaviour).

#### Glow Soft Knee
New Glow Knee slider (0.0–0.5, default 0.0) replaces the hard luminance threshold with a smoothstep fade-in. Above 0, dark pixels contribute progressively less to glow while bright pixels contribute fully — creating better contrast between lit and unlit areas. Works at Threshold=0. Suggested starting point: 0.1–0.3.

#### Halation Warmth
New Halation Warmth slider (0.0–1.0, default 0.0) controls the colour temperature of the halo. At 1.0: warm orange-red tint matching real CRT phosphor backscatter. Works alongside Desaturation: desaturation removes colour, warmth tints what replaces it.

#### Moiré Dither
New Mask Moiré Dither slider adds a small random sub-pixel phase offset per 16×16 tile, breaking the strict periodicity that causes moiré interference. Based on Haeberli & Segal (1990). Default 0.0 (off).

#### Physics-Based Radial Misconvergence
New Radial Misconvergence slider under Convergence. Implements the pincushion model Δy = k × x² — convergence error grows from zero at centre to maximum at horizontal edges, matching real CRT electron gun behaviour. Red diverges upward, blue downward. Added on top of existing uniform convergence offsets. Default 0.0 (off).

#### Per-Channel Phosphor Persistence
Three new sliders (Persistence R, G, B) allow independent decay rates per channel. Real P22 phosphors decay at different speeds: green longest (~2–3ms), red intermediate, blue fastest (~0.5ms). When any per-channel value is non-zero, they override the uniform Persistence Strength. Default 0.0 on all three (falls back to uniform).

#### Electron Beam Horizontal Bloom
New Beam Horizontal Bloom slider under Scanlines. Simulates space charge spreading of the electron beam on very bright content — saturated whites appear slightly smeared horizontally on real CRTs. Applied via a 3-tap Gaussian only above ~70% luma, with full effect above 90%. Default 0.0 (off).

#### Temporal Grain Correlation
New Temporal Grain Correlation slider under Film Grain. Real film grain has temporal coherence — silver halide crystals are fixed on the film stock. Static areas blend a fraction of the previous frame's grain, giving an anchored organic feel rather than fully re-randomised noise each frame. Moving areas always get fresh grain. Requires ENABLE_DECAY=1. Default 0.0 (off).

---

### Phosphor Profile System — Overhauled

All phosphor matrices recomputed from documented CIE xy chromaticity coordinates using the standard derivation method. Previous P22 and Trinitron matrices were incorrect.

**Profile index order changed.** Check your preset after loading.

| Index | Profile |
|---|---|
| 0 | EBU (PAL) |
| 1 | P22 (US consumer) |
| 2 | SMPTE-C / Sony BVM-D / Philips (identical chromaticities — merged) |
| 3 | Sony Trinitron |
| 4 | NTSC 1953 (Illuminant C) — new |
| 5 | NTSC 1953 D93 Japanese (~9300K) — new |

- Gamma decode/encode corrected from hardcoded pow(x, 2.2) to proper sRGB piecewise TRC
- ENABLE_PHOSPHOR now defaults to 1 (was 0 — uniforms were hidden and feature was inactive)

---

### Algorithm Quality Improvements

- **CAS sharpening** — upgraded to 8-neighbour min/max for the contrast estimate. Diagonal neighbours (NE/NW/SE/SW) now used for contrast calculation, not just N/S/E/W. More accurate on diagonal edges
- **Reconstruction filter** — `PREBLUR_FILTER` preprocessor define selects between Lanczos2 (0, default), Lanczos3 (1), and Catmull-Rom (2) for pre-blur and geometry warp centre-tap sampling
- **Phosphor persistence** — trail blend now done in linear light (gamma-correct)

---

### Preprocessor Gates — New Defines

UI categories now hide when their feature is disabled:

| Define | Default |
|---|---|
| `ENABLE_CA` | 1 |
| `ENABLE_CONVERGENCE` | 1 |
| `ENABLE_VIGNETTE` | 1 |
| `ENABLE_GRAIN` | 1 |
| `ENABLE_PREBLUR` | 1 |
| `ENABLE_HALATION` | 1 |
| `ENABLE_EDGE_BLUR` | 1 |

---

### Optimisation

- Glow H and V passes run at configurable reduced resolution (`GLOW_RESOLUTION=2` default = half res)
- Phosphor decay history stores merged from 3 passes to 2 (dual-output pass)
- Compute grain dead code removed (~267 lines)
- No-preblur + no-geometry path uses plain bilinear sampling — restored correct performance (previous version accidentally used Lanczos in blur loops when preblur was off, costing ~10fps)

---

### Compute Grain Removed

All `#if ENABLE_GRAIN_COMPUTE` dead code blocks removed. The compute grain path was non-functional. Standard Gaussian grain path unaffected.

---

### Motion-Adaptive Sharpening

`ENABLE_MOTION_SHARPEN=1` adds a separate CAS pass using frame-to-frame luma difference as a motion mask. Moving regions get stronger sharpening, static areas less. Requires ENABLE_DECAY=1. Off by default.

