# CRT-Standalone — Changelog

## Latest Update

### Phosphor Profile System — Overhauled

- All phosphor matrices recomputed from documented CIE xy chromaticity coordinates using the standard derivation method. Previous P22 and Trinitron matrices were incorrect (Trinitron had an inflated green channel producing a green tint)
- **Philips profile removed** — chromaticities are identical to SMPTE-C. Merged into a single entry: SMPTE-C / Sony BVM-D / Philips
- **Two new profiles added:**
  - NTSC 1953 (Illuminant C) — original FCC NTSC specification, very wide gamut, ~6774K white point. Early US TV receiver phosphors
  - NTSC 1953 D93 (Japanese) — same NTSC 1953 primaries with ~9300K white point. Japan never adopted SMPTE-C. Relevant for SNES, Mega Drive, Saturn content as seen on Japanese consumer CRTs
- Sony BVM-D confirmed identical to SMPTE-C — noted in tooltip. Most PS1/PS2/N64 era games were mastered on BVM-D monitors
- Gamma decode/encode in apply_phosphor corrected from hardcoded pow(x, 2.2) to proper sRGB piecewise TRC (IEC 61966-2-1)
- ENABLE_PHOSPHOR now defaults to 1 (was 0 — uniforms were hidden and feature was inactive by default)

**Note:** Profile index order changed. If you have a saved preset using Trinitron (previously index 4), it will now point to NTSC 1953. Update your preset manually:
- Old index 3 (Philips) → now index 2 (SMPTE-C / BVM-D / Philips)
- Old index 4 (Trinitron) → now index 3
- New index 4 = NTSC 1953
- New index 5 = NTSC 1953 D93

---

### Glow — Soft Knee Added

- New **Glow Knee** slider (0.0–0.5, default 0.0) under Brightness & Glow
- At 0.0: identical to previous behaviour — hard threshold, all pixels above threshold contribute equally
- Above 0: dark pixels contribute progressively less to glow while bright pixels contribute fully. Creates better contrast between lit and unlit areas, with glow feeling more localised to bright elements rather than bleeding into dark regions
- Works at Threshold=0: the knee creates a natural luminance ramp — no hard cutoff needed
- Suggested starting point: 0.1–0.3. Higher values (0.4–0.5) for high-contrast scenes
- The ideal value varies by game brightness distribution

---

### Halation — Warmth Control Added

- New **Halation Warmth** slider (0.0–1.0, default 0.0) under Halation
- At 0.0: neutral white desaturation (existing behaviour unchanged)
- At 1.0: warm orange-red tint matching real CRT phosphor backscatter — real halation has a spectral character from phosphor emission bleeding through glass
- Works alongside Desaturation: desaturation controls how much colour is removed, warmth controls the colour of what replaces it

---

### Algorithm Quality Improvements

- **CAS sharpening** upgraded to 8-neighbour min/max for the contrast estimate. Diagonal neighbours (NE/NW/SE/SW) now included in the local contrast calculation — more accurate on diagonal edges, less over-sharpening. Sharpening kernel unchanged (still 4-axis N/S/E/W)
- **Reconstruction filter** now selectable via `PREBLUR_FILTER` preprocessor define:
  - 0 = Lanczos2 (4×4=16 taps, default)
  - 1 = Lanczos3 (6×6=36 taps, ~2× cost, sharpest)
  - 2 = Catmull-Rom (4×4=16 taps, same cost as Lanczos2, bicubic spline — crispest edges)
  - Applies to pre-blur passes and geometry warp centre-tap sampling
- **Phosphor persistence** gamma-correct: trail blend now done in linear light (lerp in linear, re-encode) rather than sRGB space

---

### Preprocessor Gates — New Defines

The following features now hide their UI sliders and compile out when set to 0:

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

### Compute Grain Removed

- All `#if ENABLE_GRAIN_COMPUTE` dead code blocks removed (~267 lines). The compute grain path was non-functional and produced incorrect output. Standard Gaussian grain path is unaffected

---

### Motion-Adaptive Sharpening (New Pass)

- `ENABLE_MOTION_SHARPEN=1` adds a separate CAS sharpening pass that uses frame-to-frame luma difference as a motion mask
- Moving regions receive stronger sharpening; static areas receive little or none
- Complements BFI by counteracting sample-and-hold blur on moving objects
- Requires `ENABLE_DECAY=1` for the motion reference frame
- Off by default

---

### Optimisation

- Glow H and V passes now run at configurable reduced resolution (`GLOW_RESOLUTION`, default 2 = half res). Glow is a wide low-frequency effect — half resolution is perceptually indistinguishable
- Phosphor decay history stores merged: `RawCapture` and `Prev1Store` combined into a single dual-output pass (`PhosphorDecayStoreRawPrev1`), saving one full-resolution pass
