# CRT-Standalone — Changelog

All notable changes to this project are documented here.
Versioning follows [Semantic Versioning](https://semver.org/): MAJOR.MINOR.PATCH.
- **MAJOR** — incompatible architectural change
- **MINOR** — new features or breaking preset changes (re-tuning required)
- **PATCH** — bug fixes that preserve existing preset behaviour

---

## [1.0.1] — 2025-05

### New Features

#### Edge Feedback (`ENABLE_EDGE_FEEDBACK=1`)
Amplifies CRT edge and peripheral effects by comparing the current pixel against its neighbours from the previous rendered frame. The cross-frame difference captures accumulated CRT processing (mask, scanlines, vignette, geometry warp) and feeds it back as edge enhancement. Originally intended as broadcast pre-emphasis simulation — the unexpected cross-frame interaction produces a more interesting and distinctive analogue effect. Most effective with `ENABLE_GEOMETRY=1`. Two controls: Edge Feedback Strength (luma edge amplification) and Chroma Diffusion (horizontal colour softening using previous frame reference).

#### Noise Floor (`ENABLE_NOISE_FLOOR=1`)
Fixed-pattern thermal noise from CRT electronics, visible on near-black areas. Uses `grain_uhash` for a stable per-pixel pattern that drifts slowly (every 4 frames via `FRAMECOUNT/4` temporal salt) — slower than film grain but not static. Gated below ~50% luma so it's invisible on bright content. Dedicated pass after grain, before phosphor decay.

#### White Point (under Phosphor Profile)
Chromatic adaptation slider using proper D55/D93 matrices from CRT Guest Advanced. Shifts the display white point from warm D55 (~5500K, older consumer CRTs) through neutral D65 to cool D93 (~9300K, Japanese consumer CRTs). More physically accurate than the existing Colour Temperature slider since it uses full chromatic adaptation rather than a simple linear tint.

#### Spot Size / Overbrightness (under Scanlines)
Luminance-squared brightness boost on peak white content, simulating the physical growth of the CRT electron beam spot at high current. `boost = 1 + spot_size × luma²` — dark pixels unaffected, highlights progressively brightened. In HDR pipeline (`PIPELINE=1`) this correctly lifts highlights above the SDR ceiling.

#### Vertical Beam Spread (under Convergence)
Per-channel vertical blur simulating the physical offset of the three electron guns in a colour CRT. R channel gets ±0.5px spread, B gets ±0.3px, G unchanged. Intentionally subtle — contributes to overall organic feel. Only active in `ENABLE_PREBLUR=1` path.

### Bug Fixes

- Phosphor profile matrices: NTSC 1953 and NTSC 1953 D93 were computed with an incorrect white point. Recomputed from first principles using Illuminant C (0.3101, 0.3162) for NTSC 1953 and D93 (0.2848, 0.2932) for the Japanese variant. Other profiles (EBU, P22, SMPTE-C, Trinitron) verified correct
- Colour temperature redefinition: `crt_colour_temp` was being declared twice after the white point addition. Resolved by renaming the new chromatic adaptation control to `crt_white_point`
- Matrix ternary operator: HLSL does not support `?:` on `float3x3` types in all shader models. Replaced with `if/else` branch
- `static const` inside function scope: `kXYZ_to_sRGB` was declared inside an `if` block which is invalid in FXC. Moved to file scope

---

## [1.0.0] — 2025-05 — Initial public release

First public release. Feature-complete CRT emulation shader for ReShade targeting QD-OLED and high-resolution SDR displays.

### Core CRT Pipeline
- Pre-blur (H+V Gaussian, Lanczos2/3, Catmull-Rom) acting as analogue AA
- Megatron cubic Bezier per-channel scanline beam model
- Luminance-dependent beam width modulation (`ENABLE_BEAM_MODULATION`)
- Scanline beam snapped to integer pixel rows — eliminates oscillating size and mask inconsistency
- Scanline sigma in pixel units (not normalised period units)
- Resolution-independent scanline width via `SCANLINE_REFERENCE_HEIGHT`
- Shadow mask: 8 types including QD-OLED Delta and Luma Gate
- Mask moiré dither (Haeberli & Segal 1990)
- Per-channel phosphor profiles (6 types: EBU, P22, SMPTE-C, Trinitron, NTSC1953, NTSC1953-D93)
- Megatron Bezier BCS in Yxy space (no washout)
- Colour temperature adjustment

### Glow & Halation
- Dual-scale bloom (tight + wide glow passes)
- Spectral bloom (per-channel sigma based on wavelength)
- Glow soft knee
- Halation warmth (neutral to warm orange-red)
- Electron beam horizontal bloom (luma-gated)

### HDR Pipeline (`PIPELINE=1/2`)
- scRGB and HDR10 Soop sandwich integration
- BCS corrected for HDR pipeline (decode before Bezier, re-encode after)
- Variable MPRT (Blur Busters algorithm, MIT licence)
- Fibonacci phosphor persistence

### Geometry & Distortion
- Full geometry warp with Lanczos reconstruction (`ENABLE_GEOMETRY`)
- Lightweight post-process barrel/pincushion warp (`ENABLE_LIGHT_WARP`)
- Pin phase horizontal linearity distortion (Sony Megatron approach)

### Convergence & CA
- Vertical per-channel convergence offsets (R/G/B)
- Horizontal per-channel convergence offsets (R/B)
- Radial misconvergence (pincushion model)
- Radial chromatic aberration

### Screen & Presentation
- Vignette: rectangular (authentic CRT) and circular modes
- Highlight protection: threshold + strength sliders (linear ramp in sRGB space)
- Corner rounding with border shadow (Guest Advanced approach, GPL v2+)
- Edge blur (radial optical defocus)
- Post-scanline softening
- CAS sharpening (AMD, MIT)
- Motion sharpening

### Interference (`ENABLE_INTERFERENCE`)
All signal-level effects applied as a single post-process pass after all CRT rendering. Based on NewPixie (MIT/PD):
- Wiggle: triple-sine horizontal displacement, resolution-scaled
- Rolling scanlines: sync instability at screen-resolution frequency
- Hum bars: AC mains interference scrolling gradient
- Ghost image: per-channel displaced samples with fixed offset + animated wobble, resolution-scaled
- Accumulate modulation: `max(prev × modulate, current × 0.96)` phosphor afterglow

### Interlace (`ENABLE_INTERLACE`)
Field-based scanline blanking alternating every frame. BFI-cycle aware. Incompatible with out-of-ReShade frame generation (Smooth Motion, LSFG).

### Film Grain
- Poisson variance grain (inspired by METEOR, Marty McModding)
- Spatial diffusion via separate GrainDiffuse pass
- Per-channel colour grain option
- Grain size, intensity, shadow weight controls

### Bug Fixes (accumulated during development)
- Beam sigma double-falloff: `megatron_scanline × gauss` compound removed; beam modulation now uses Gaussian only
- Beam sigma units corrected from normalised period to pixel units
- Scan_width integer snap: non-integer widths caused oscillating scanline sizes and inconsistent mask darkness
- `floor(fc.y) + 0.5` pixel row snapping: eliminated irregular scanlines from float precision at 4K
- BCS pipeline fix: HDR path now decodes to linear before Bezier, re-encodes after
- Luma monitor ping-pong: fixed D3D X3020 same-pass read/write error
- `FRAMECOUNT`, `CRT_TIMER`, `CRT_FRAMETIME` moved outside `ENABLE_GRAIN` gate
- `ENABLE_GRAIN=0` compile fix
- `GLOW_RESOLUTION > 1` mini-screen artefact noted (set to 1 for affected games e.g. Cuphead)

### Known Issues
- Software BFI incompatible with VRR (frame timing unpredictable)
- Variable MPRT incompatible with HDR pipeline (red tint warning displayed)
- `ENABLE_INTERLACE` incompatible with Nvidia Smooth Motion and LSFG
- `GLOW_RESOLUTION > 1` may cause double-image in some games — set to 1

