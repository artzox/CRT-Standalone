# CRT-Standalone — Changelog

## Latest Update

### New Features

#### Lightweight Barrel Warp (`ENABLE_LIGHT_WARP=1`)
Post-process barrel/pincushion distortion applied to the final image. Much cheaper than full geometry — no Lanczos reconstruction, no glow/halation correction passes. The entire scene including scanlines and mask bends with the warp. Only active when `ENABLE_GEOMETRY=0`. Controls: Warp Strength (positive=barrel, negative=pincushion) and Border Colour.

#### Interlaced Field Simulation (`ENABLE_INTERLACE=1`)
Simulates CRT interlaced mode by alternating which scanline rows are bright and dark each frame, matching real CRT field-based display. Implemented inside the scanline calculation so the actual dark gaps between scanlines move position rather than the whole image shifting. Automatically divides by the BFI cycle length (`crt_decay_frames`) so the field alternation stays in sync with lit frames. Most visible at high framerates with BFI active.

#### Corner Rounding (`ENABLE_CORNER_ROUND=1`)
Rounded screen mask based on the CRT Guest Advanced corner() function. Three controls: Corner Size (radius), Border Size (independent edge shadow on all four sides simulating bezel housing shadow), and Border Intensity (power curve controlling sharpness). The mask is a luminance multiplier — darkens toward edges and corners naturally, no flat bezel colour needed. No separate colour picker required.

#### Hum Bars (`ENABLE_HUM_BARS=1`)
Simulates AC mains interference — a slow-moving sawtooth brightness gradient matching the Guest Advanced `humbars()` implementation. Two controls: Intensity (positive = dark bar, negative = bright bar) and Speed (50 = 50Hz PAL, 60 = 60Hz NTSC). Applied after vignette, before glow. Off by default, gated by `ENABLE_HUM_BARS` to keep interface clean.

#### Horizontal Convergence
Two new sliders under Convergence: Red Horizontal and Blue Horizontal. Independent X offset per channel, complementing the existing vertical convergence offsets. Real CRTs had convergence errors in both axes. Compounds with vertical convergence and radial CA.

#### Pin Phase (`ENABLE_LIGHT_WARP=1`)
Sony Megatron-style horizontal scan linearity error: `uv.x *= 1 + pin_phase * uv.y`. Models real CRT deflection yoke geometry where horizontal linearity changes with vertical deflection angle. Different from radial barrel warp — distorts only horizontally. Can be combined with Warp Strength for stacked effects. Slider under Light Warp category.

#### Scanline Resolution Independence (`SCANLINE_REFERENCE_HEIGHT`)
New preprocessor define (default 0 = disabled). Set to your display's native vertical resolution (2160 for 4K, 2880 for 5K). When set, `crt_scanline_width` is automatically scaled proportionally to render resolution, so the same scanline width value produces identical-looking scanlines in every game regardless of their internal render resolution. Existing presets unaffected when disabled.

---

### Improvements

#### Vignette HDR Protection — Reworked
Replaced single threshold with two-slider system: **Highlight Protection Threshold** (where protection begins) and **Highlight Protection Strength** (0.0 = original behaviour, 1.0 = full isolation of highlights above threshold). The gate now applies before the strength lerp for consistent behaviour across both rectangular and circular vignette shapes.

#### BFI/Pipeline Contrast Fix
In `PIPELINE>=1`, the BCS contrast curve now decodes from sRGB to linear before `apply_bcs` and re-encodes after. Previously the Bezier curve operated on already-gamma-encoded values causing the internal `pow(Y, 1/2.4)` step to double-encode, producing different contrast behaviour in HDR mode vs SDR.

#### Ping-Pong Textures for Luma Monitors
`crt_decay_luma_lit_tex` and `crt_decay_luma_dark_tex` were being both read and written in the same pass, causing a D3D `X3020` error on some drivers. Fixed with dedicated `_prev_tex` copies updated each frame before the monitor update passes.

---

### Removed

#### Temporal Grain Correlation
Removed. The implementation produced grain elements that were too large and reduced image clarity even when technically functional. The grain system otherwise unchanged — per-frame Poisson noise with spatial diffusion via `crt_grain_size`.

---

### Compile Fixes

- `FRAMECOUNT`, `CRT_TIMER`, and `CRT_FRAMETIME` were declared inside `#if ENABLE_GRAIN`. When `ENABLE_GRAIN=0` these were undefined but referenced by interlace, burn-in, and decay code. Moved to a system uniforms block that is always compiled in.
- `crt_grain_raw_tex` self-sampling error: `GrainMerged` was writing to `crt_grain_raw_tex` (RenderTarget1) while the temporal grain code read from the same texture, triggering `X3020`. Fixed by removing temporal grain entirely.

---

## Previous Version

### New Features

#### Dual-Scale Bloom
Wide glow pass at half resolution adds broad area bloom complementing the tight per-element glow. Three controls under Brightness & Glow: Wide Glow Strength (default 0.0), Wide Glow Radius, Wide Glow Threshold.

#### Spectral Bloom
Per-channel glow sigma: blue blooms wider than red (R=0.75×, G=1.0×, B=1.35×) based on wavelength-dependent diffraction. Controlled by Spectral Bloom slider (default 0.0 = uniform).

#### Glow Soft Knee
Glow Knee slider replaces hard luminance threshold with smoothstep fade-in. Dark pixels contribute progressively less to glow. Works at Threshold=0.

#### Halation Warmth
Halation Warmth slider controls colour temperature of the halo — neutral white to warm orange-red matching real CRT phosphor backscatter.

#### Moiré Dither
Mask Moiré Dither adds random sub-pixel phase offset per 16×16 tile, breaking mask periodicity. Based on Haeberli & Segal (1990).

#### Radial Misconvergence
Convergence error grows toward screen edges following Δy = k × x² (pincushion model). Red diverges up, blue down at edges.

#### Per-Channel Phosphor Persistence
Persistence R/G/B sliders for independent decay rates. Real P22: green longest (~2–3ms), blue fastest (~0.5ms).

#### Electron Beam Horizontal Bloom
Luminance-gated 3-tap horizontal Gaussian on very bright scanlines (>70% luma gate). Simulates space charge beam spreading.

### Phosphor Profile Overhaul
All matrices recomputed from documented CIE xy chromaticity coordinates. Two new profiles: NTSC 1953 (Illuminant C) and NTSC 1953 D93 (Japanese ~9300K). Philips merged into SMPTE-C (identical chromaticities). Gamma corrected from hardcoded 2.2 to proper sRGB piecewise TRC. `ENABLE_PHOSPHOR` defaults to 1.

**Profile index order changed** — check presets after updating.

### Preprocessor Gates
New defines with UI hiding: `ENABLE_CA`, `ENABLE_CONVERGENCE`, `ENABLE_VIGNETTE`, `ENABLE_GRAIN`, `ENABLE_PREBLUR`, `ENABLE_HALATION`, `ENABLE_EDGE_BLUR`.

### Reconstruction Filter
`PREBLUR_FILTER` selects between Lanczos2 (0), Lanczos3 (1), Catmull-Rom (2) for pre-blur and geometry warp sampling.

### Optimisation
No-preblur + no-geometry path restored to plain bilinear (Lanczos was accidentally used in blur loops, costing ~10fps). Glow and halation blur passes use correct sampling paths per pipeline.

### Compute Grain Removed
~267 lines of dead `#if ENABLE_GRAIN_COMPUTE` code removed.

