# CRT-Standalone Shader — User Guide

## Getting Started

### Installation
1. Copy `CRT-Standalone.fx` into your game's ReShade `Shaders` folder
2. Enable the `CRT_Standalone` technique in the ReShade overlay
3. Configure preprocessor definitions and sliders to taste

### Preprocessor Definitions
Set these in the ReShade **Preprocessor Definitions** panel (not the sliders):

| Define | What to set |
|---|---|
| `PIPELINE` | **0** = SDR (default). **1** = scRGB HDR (recommended for HDR games with Soop). **2** = HDR10 / wide-gamut (use if the game outputs DCI-P3 or BT.2020 — see Troubleshooting) |
| `GLOW_RESOLUTION` | **2** = half resolution (default, recommended). **1** = full resolution (use if you see double-image artefacts or aliasing on glow — expect a performance penalty) |
| `ENABLE_GEOMETRY` | **1** to enable screen curvature warp with Lanczos reconstruction |
| `ENABLE_LIGHT_WARP` | **1** for lightweight barrel distortion (cheaper than full geometry) |
| `ENABLE_CORNER_ROUND` | **1** for rounded screen corners with bezel shadow |
| `ENABLE_INTERLACE` | **1** for interlaced field simulation (needs BFI or high framerate) |
| `ENABLE_INTERFERENCE` | **1** for signal interference effects (wiggle, ghost, rolling scanlines, hum bars) |
| `ENABLE_DECAY` | **1** to enable phosphor persistence / BFI system |
| `ENABLE_BEAM_MODULATION` | **1** for luminance-dependent beam width |
| `SCANLINE_REFERENCE_HEIGHT` | Set to your display height (e.g. **2160** for 4K, **2880** for 5K) for resolution-independent scanline width |

### Recommended Starting Points

**QD-OLED HDR (e.g. Sony A95L) — Soop pipeline:**
```
PIPELINE=1
GLOW_RESOLUTION=2
SCANLINE_REFERENCE_HEIGHT=2880  (or 2160 for 4K)
ENABLE_DECAY=1
```
Set `crt_scanline_width` to 6–8 at 5K, 4–6 at 4K. Enable BFI (`crt_decay_frames=2`) if your display supports it. Adjust `crt_soop_peak_nits` to match your display's peak brightness.

**SDR / Generic display:**
```
PIPELINE=0
GLOW_RESOLUTION=2
ENABLE_DECAY=0
```
Start with default sliders. Set `crt_scanline_width` to 3–4 at 1080p, 5–6 at 1440p.

**Pixel art / retro games (240p–480p content):**
Increase `crt_scanline_width` so scanlines are visibly thick. Enable `ENABLE_PREBLUR` and raise `crt_preblur_h_sigma` slightly to soften pixel edges before the CRT processing.

---

## Overview

CRT-Standalone is a comprehensive CRT display simulation shader for ReShade. It covers the full signal chain of a real CRT — from pre-processing through phosphor simulation — and includes an optional BFI (Black Frame Insertion) system for reducing sample-and-hold motion blur on modern LCD/OLED displays.

---

## Requirements

- ReShade 5.x or 6.x (see version notes below)
- DirectX 11 or 12 / OpenGL 4.3+ / Vulkan
- **Recommended:** ReShade 6.62 or earlier for BFI use (see known issues)

---

## Installation

1. Copy `CRT-Standalone.fx` into your game's ReShade `Shaders` folder
2. Enable the technique in the ReShade overlay
3. The shader compiles with default settings — most features are on by default

---

## Preprocessor Defines

Set these in the ReShade overlay under **Preprocessor Definitions** to enable/disable features at compile time. Disabling unused features reduces GPU cost.

### Feature Toggles

| Define | Default | Description |
|---|---|---|
| `ENABLE_PREBLUR` | 1 | Pre-blur pass — softens source before CRT processing. Also acts as a mild AA at full resolution |
| `ENABLE_MASK` | 1 | Shadow mask / aperture grille simulation |
| `ENABLE_GAMMA_CORRECT` | 1 | Input/output gamma correction |
| `ENABLE_BEAM_MODULATION` | 1 | Per-channel scanline beam width modulation |
| `ENABLE_HALATION` | 1 | Phosphor halation (light scatter behind glass) |
| `ENABLE_EDGE_BLUR` | 1 | Screen edge blur — simulates CRT aperture falloff |
| `ENABLE_SCANLINE_SOFTEN` | 1 | Post-scanline vertical softening |
| `ENABLE_SHARPEN` | 1 | Contrast-adaptive sharpening (CAS) |
| `ENABLE_MOTION_SHARPEN` | 0 | Motion-adaptive sharpening — enable alongside BFI |
| `ENABLE_PERSISTENCE` | 0 | Phosphor persistence simulation |
| `ENABLE_DECAY` | 0 | BFI / Variable MPRT / Fibonacci phosphor decay |
| `ENABLE_BURNIN_PHASE` | 1 | Anti burn-in phase shifting |
| `ENABLE_BURNIN_ORBIT` | 1 | Anti burn-in orbital drift |
| `ENABLE_PHOSPHOR` | 1 | Phosphor colour profile |
| `ENABLE_GEOMETRY` | 0 | Screen geometry / curvature (experimental) |
| `ENABLE_CA` | 1 | Chromatic aberration |
| `ENABLE_CONVERGENCE` | 1 | Convergence error simulation |
| `ENABLE_VIGNETTE` | 1 | Vignette (edge darkening) |
| `ENABLE_GRAIN` | 1 | Film grain |
| `ENABLE_LIGHT_WARP` | 0 | Lightweight barrel/pincushion distortion (only active when ENABLE_GEOMETRY=0) |
| `ENABLE_INTERLACE` | 0 | Interlaced field simulation — alternates scanline fields each frame |
| `ENABLE_CORNER_ROUND` | 0 | Rounded screen corners with optional bezel border shadow |

### Resolution / Quality Defines

| Define | Default | Description |
|---|---|---|
| `HALATION_RESOLUTION` | 4 | Halation blur resolution divisor. 4=quarter res (recommended), 2=half, 1=full |
| `GLOW_RESOLUTION` | 2 | Glow blur resolution divisor. 2=half res (recommended), 1=full |
| `PREBLUR_RESOLUTION` | 1 | Pre-blur resolution. Keep at 1 — lower values visibly degrade quality |
| `PREBLUR_FILTER` | 0 | Reconstruction filter for pre-blur and geometry warp sampling. 0=Lanczos2 (default, 4×4 taps), 1=Lanczos3 (6×6 taps, sharper, ~2× cost), 2=Catmull-Rom (4×4 taps, crispest edges at same cost as Lanczos2) |
| `SCANLINE_REFERENCE_HEIGHT` | 0 | Resolution-independent scanline width. Set to your display's native vertical resolution (2160=4K, 2880=5K). When set, `crt_scanline_width` produces identical-looking scanlines at any render resolution. 0=disabled (default, preserves existing preset behaviour) |

### HDR / Pipeline

| Define | Default | Description |
|---|---|---|
| `PIPELINE` | 0 | 0=SDR, 1=scRGB (Soop), 2=HDR10 (Soop) |
| `LINEAR_HDR_INPUT` | 0 | 0=XYZ/Yxy path, 1=raw linear RGB |

### BFI / Decay

| Define | Default | Description |
|---|---|---|
| `FRAMEGEN_PHASE_OFFSET` | 0 | Phase offset for frame generation (0 or 1). Use 1 if BFI phase is inverted |
| `CRT_FRAMETIME_EXPECTED` | 8.33 | Expected frame period in ms for spike detection. Change for non-120Hz: 6.94=144Hz, 6.06=165Hz |

---

## Settings Reference

### Pre-Blur
Softens the source image before it enters the CRT simulation pipeline. At `PREBLUR_RESOLUTION=1` it also functions as a mild AA pass. Increase H/V sigma for stronger softening. Keep radius low (2–3) for performance.

### Shadow Mask

Controls the phosphor pattern simulation.

**Mask Type** — six options:

| # | Name | Description |
|---|---|---|
| 0 | Aperture Grille | Standard vertical RGB stripe pattern. Mimics Sony Trinitron/Mitsubishi Diamondtron tubes. Clean horizontal structure, high brightness |
| 1 | Diagonal Aperture Grille | Same as Aperture Grille but each row is offset by half a triad width. Distributes the phosphor structure diagonally — reduces moiré and interference with QD-OLED triangular subpixel layouts |
| 2 | Slot Mask | Aperture grille plus alternating dark horizontal rows, simulating the slots between phosphor rows in shadow mask CRTs. Adds a two-dimensional structure — more "CRT" looking than pure aperture grille at the cost of brightness |
| 3 | Trinitron | Wider green phosphor stripe (~50% of triad width), narrower R/B. Matches real Sony Trinitron phosphor proportions where green was physically larger. Sharper edges than standard aperture grille |
| 4 | QD-OLED Delta | Simulates the physical triangular subpixel layout of QD-OLED panels (A95L and similar). Green phosphors at corners, red and blue alternating. Designed for 1:1 pixel mapping — see QD-OLED guide below |
| 5 | QD-OLED Luma Gate | Same subpixel pattern as QD-OLED Delta but with luminance-weighted mask application. Dark pixels receive full mask structure; bright pixels gradually pass through unmasked. Matches real CRT phosphor behaviour where bright areas bleed light that fills adjacent gaps |

**Common mask settings:**

- **Triad Width** — size of one RGB triad in pixels at 4K reference resolution. 1.0 = very fine, 3.0+ = visible pixel structure. For QD-OLED at native 1:1 mapping, use 1.0 for 4k, 1.5 for 5k
- **Mask Strength** — how strongly the mask darkens non-phosphor areas. 0.3–0.6 typical for CRT feel. See QD-OLED Luma Gate guide for calibration workflow
- **Mask Boost** — compensates for brightness loss by brightening lit phosphor areas. Raise alongside Mask Strength to maintain overall luminance
- **Phosphor Sharpness** — edge softness of individual phosphor cells. Higher = harder edges
- **Slot Mask Row Darkness** — only for type 2. Controls how dark the slot rows are. 0 = no slots, 1 = fully black rows
- **QD-OLED Mask Offset X/Y** — fine-tune the subpixel pattern alignment in pixels. Adjust if the mask tiles don't align correctly with your panel's physical subpixel layout
- **Mask Moiré Dither** — adds a small random sub-pixel phase offset to the mask pattern within each 16×16 tile, breaking the strict periodicity that causes moiré interference with certain image frequencies. 0.0 = off (default). 0.3–0.5 = noticeable moiré reduction. Based on Haeberli & Segal (1990) display simulation work

---

#### QD-OLED Mask Guide

QD-OLED panels have a triangular RGB subpixel layout rather than the standard vertical stripe arrangement. The QD-OLED Delta and QD-OLED Luma Gate mask types are designed to match this physical structure.

**Critical: 1:1 pixel mapping required**

For the mask to accurately represent the physical subpixel layout, the game must render at your display's native resolution with no supersampling or DSR. The triad pattern must map one virtual phosphor cell to one physical display pixel.

The correct Triad Width for 1:1 native mapping depends on your display resolution:
- **4K display:** Triad Width = **1.0**
- **5K display:** Triad Width = **1.5**

The test for correct 1:1 alignment: set Mask Strength to 1.0 (100%). The image should go **black** — all phosphor gaps visible, no channel dominating. If the image appears predominantly green at full strength, the triad width is not at 1:1 and the pattern does not match your panel's physical subpixel layout.

Values above the 1:1 setting scale up the pattern — useful for making the structure more visible or for lower-resolution sources, but no longer matching the physical panel.

---

#### QD-OLED Luma Gate Calibration Workflow

The Luma Gate type (mask 5) is luminance-weighted — bright pixels pass through cleanly while dark areas receive the full phosphor texture. This requires calibration to ensure highlights look correct before dialling back mask strength.

**Calibration steps:**

1. Set **Mask Strength to 1.0** (maximum). This gives you full visibility of the mask effect across all luminance levels
2. Navigate in the game to a scene with the **brightest highlights** you expect to encounter — direct sunlight, light sources, blown-out sky
3. Adjust the **Mask Boost** and **Phosphor Sharpness** sliders until the bright highlights look correct — they should appear clean and bright with minimal visible phosphor structure. The luma gate automatically reduces the mask on these pixels; your task here is to ensure the gate threshold is well placed
4. Check dark and midtone areas — they should show clear phosphor texture. If they look too dark, raise Mask Boost. If the texture is too harsh, lower Phosphor Sharpness
5. Once you are satisfied with how the image looks at Mask Strength 1.0, **set Mask Strength back to your preferred value** (typically 0.4–0.7). The calibration you did at full strength defines the character of the effect; reducing strength scales it proportionally without changing the highlight behaviour

- **Phosphor Dot Structure** — subtle per-dot luminance variation simulating manufacturing imperfections in the phosphor coating. Uses spatially-correlated 3×3 neighbourhood averaging so adjacent dots vary smoothly rather than per-pixel noise. Pattern re-randomises every 10 minutes for burn-in protection. 0.005–0.015 = authentic subtle texture, above 0.02 becomes noticeably uneven

**Anti Burn-In** — two mechanisms to prevent static mask patterns from burning into the panel, using integer triad-width steps (visually identical but different display pixels receive each phosphor). Phase: half-triad alternation on a slow timer. Orbit: quarter-triad stepping through 4 positions. Both require their respective `ENABLE_BURNIN_PHASE` / `ENABLE_BURNIN_ORBIT` gates.

### Scanlines
- **Scanline Strength** — depth of dark scanlines between phosphor rows
- **Scanline Sigma** — softness of the scanline edge
- **Per-channel attack** — how much each channel contributes to the scanline modulation
**Beam Sigma** controls the width of the electron beam Gaussian in pixel units (requires `ENABLE_BEAM_MODULATION=1`). There are two separate sliders — one for dark pixels and one for bright pixels — that define the range of beam widths used across the luminance range:

- **Beam Sigma Dark (pixels)** — beam width applied to dark pixels (signal near black). Lower = tighter beam with deeper dark gaps between scanlines. Rule of thumb: keep below `scanline_width / 4` for visible gaps. Example: at Scanline Width 4, Dark Sigma 0.5 gives `0.5/4 = 0.125` normalised sigma — deep gap. Dark Sigma 1.5 gives `1.5/4 = 0.375` — gap nearly filled with haze
- **Beam Sigma Bright (pixels)** — beam width applied to bright pixels (signal near white). Higher = the beam spreads wider, partially filling the scanline gap on bright content. Physically models how a CRT electron beam widens at higher current draw. Should always be ≥ Dark Sigma
- **Combined behaviour:** mid-grey pixels use the interpolated value between dark and bright sigma. Set both sliders to the same value for uniform beam width across all luminance levels. Set bright higher than dark to get the authentic CRT effect where bright content bleeds more into the gaps
- **Spot Size / Overbrightness** — luminance-squared brightness boost on peak white content, simulating how a CRT electron beam spot physically grows at high current. Dark pixels unaffected, bright pixels progressively boosted. In HDR pipeline this lifts highlights above SDR ceiling. 0.1–0.3 = subtle, 0.5 = strong
- **Beam Horizontal Bloom** — simulates electron beam horizontal spreading on very bright scanlines. On real CRTs, high-current beams (saturated whites) spread sideways due to space charge repulsion between electrons. Only active above ~70% luma, with full effect above 90%. 0.0 = off (default). 0.3–0.5 = subtle spreading on bright highlights

**Note on Scanline Width:** The shader snaps `crt_scanline_width` to the nearest integer internally. Non-integer values caused some pixel rows to sample at the bright scanline centre while neighbouring rows sampled at the dark edge, producing oscillating scanline sizes and inconsistent mask darkness as the width slider was moved. Integer-snapping ensures every N rows form one clean scanline period

### Interlace

Requires `ENABLE_INTERLACE=1`. Simulates CRT interlaced mode by alternating which scanline fields are bright and dark each frame — matching how real interlaced CRTs displayed odd and even fields on alternate fields. Produces visible field-rate flicker, most noticeable at high framerates with BFI active.

- **Interlace Strength** — 0.0 = no effect. 1.0 = full field blanking (dark rows go completely black on alternate frames). 0.3–0.5 = softer look. Automatically accounts for BFI cycle length so the field alternation stays in sync with lit frames

**Note:** Not compatible with frame generation that runs outside ReShade (Nvidia Smooth Motion, LSFG). Generated frames are invisible to FRAMECOUNT, causing the field pattern to become irregular. DLSS Frame Generation (which runs inside ReShade's pipeline) works correctly

### Halation

- **Strength** — overall halation intensity
- **Radius** — how far halation spreads
- **Sigma** — falloff shape within the radius
- **Desaturation** — how much the halo desaturates toward the warm tint colour. 0 = full colour scatter, 1 = fully desaturated
- **Warmth** — colour temperature of the halo. 0.0 = neutral white, 1.0 = warm orange-red tint matching real CRT phosphor backscatter. Works alongside Desaturation
- **Threshold** — luminance gate — only bright pixels produce halation
- **Anisotropy** — horizontal vs vertical spread ratio

### Beam Modulation
Controls how beam width varies with signal level — brighter pixels produce wider, softer beams.

- **Min/Max Sigma** — beam width range from dark to bright pixels

### Glow
A wide soft bloom applied to bright image areas.

- **Threshold** — luminance above which glow starts
- **Knee** — controls how selectively glow is applied across luminance levels. 0.0 = original behaviour, all pixels above threshold contribute equally. Above 0, dark pixels contribute progressively less to glow while bright pixels contribute fully — creating better contrast between lit and unlit areas, with glow feeling more localised to bright elements rather than bleeding into dark regions. Works even at Threshold=0: the knee creates a natural luminance ramp suppressing dark pixel contribution without a hard cutoff. Suggested starting point: 0.1–0.3. Higher values (0.4–0.5) are more aggressive and best suited to high-contrast scenes. The ideal value varies by game brightness distribution
- **Strength** — how bright the glow is
- **H/V Radius** — how far glow spreads horizontally and vertically
- **Sigma** — falloff shape within the radius
- **H Mix** — blend between horizontal and vertical glow contributions
- **Balance** — between glow contributing additively vs multiplicatively
- **Wide Glow Strength** — second, larger bloom pass running at quarter resolution. Adds a broad soft halo over large bright areas (sky, windows, surfaces), complementing the tight per-element glow. 0.0 = off (default). 0.1–0.3 = subtle area bloom
- **Wide Glow Radius** — radius of the wide bloom in pixels. Keep well above the tight glow radius
- **Wide Glow Threshold** — luminance threshold for the wide bloom. Typically set lower than the tight glow threshold
- **Spectral Bloom** — physically based chromatic bloom: blue light diffracts more than red through a lens, so the blue channel blooms wider. 0.0 = uniform (default). 0.5 = subtle coloured fringe on bright highlights. Based on wavelength-dependent diffraction



### Chromatic Aberration
Radial colour fringing simulating glass lens dispersion. Zero at screen centre, maximum at corners.

- **CA Strength** — magnitude. 0.002–0.005 = subtle, 0.01+ = strong
- **CA Falloff** — how the CA builds toward edges. 1=linear, 2=quadratic (default, physically accurate), 3+=concentrates at corners

### Convergence
Simulates CRT electron gun misregistration — independent vertical offset per R/G/B channel. Different from CA (which is radial/lens-based). Both can be used simultaneously.

- **R/G/B Vertical** — uniform vertical offset per channel in pixels
- **Vertical Beam Spread** — slight per-channel vertical blur simulating the physical offset of the three electron guns in a colour CRT. R and B channels get different spread amounts (R slightly more than B, G unchanged). Very subtle by design — contributes to overall organic feel rather than being identifiable on its own. 0.3–0.7 = authentic range
- **Red/Blue Horizontal Convergence** — independent horizontal X offset per channel, complementing the existing vertical offsets. Real CRTs had convergence errors in both axes
- **Radial Misconvergence** — physically based pincushion model: convergence error grows toward the screen edges following Δy = k × x². Zero at centre, maximum at horizontal edges. Red diverges upward, blue downward — matching real pincushion misconvergence geometry. Added on top of uniform offsets. 0.0 = off (default). 0.5–1.0 = subtle authentic edge fringing

### Vignette
Edge darkening.

- **Shape** — Circular/Elliptical (default, original oval) or Rectangular (CRT-authentic H×V falloff with naturally darker corners)
- **H Power** — falloff speed horizontally. In Circular mode, controls overall power
- **V Power** — falloff speed vertically. No effect in Circular mode. Keep 1.0–2.5 in Rectangular mode to avoid a sliver effect
- **Strength** — overall vignette intensity
- **Highlight Protection Threshold** — luminance above which highlights are progressively protected from vignette darkening
- **Highlight Protection Strength** — how strongly highlights are protected. 0.0 = original behaviour (no protection). 1.0 = full protection: pixels at peak brightness receive zero vignette darkening. Use threshold to define where protection starts, strength to control how complete it is

### Film Grain
- **Animate** — grain changes each frame (recommended)
- **Colour** — independent per-channel grain (film-like). Off = monochrome grain
- **Intensity** — grain amplitude. 0.15–0.25 is typical. Higher values darken bright areas due to Poisson variance rolloff
- **Shadows** — minimum grain level in shadow areas
- **Grain Size** — diffusion spread of grain clusters. 0.2 = fine (default). Higher = larger organic clumps

### Gamma & Contrast

- **CRT Gamma (Input)** — gamma of the source signal. 2.4 = standard sRGB
- **Display Gamma (Output)** — target display gamma. 2.2 = typical LCD
- **Brightness** — global exposure offset
- **Contrast** — expands or compresses the luminance range
- **Saturation** — colour saturation adjustment
- **Colour Temperature** — warm/cool white point shift

### Phosphor Profile

Remaps game colours through a chosen CRT phosphor primary set to CIE XYZ, then to your display gamut. All matrices computed from documented CIE xy chromaticity coordinates.

**Important:** If you have an existing preset saved with Trinitron or later profiles, the index order changed in this version — check your selected profile after loading. Philips (formerly index 3) has been merged into SMPTE-C as they share identical chromaticities.

| Index | Profile | Notes |
|---|---|---|
| 0 | EBU (PAL) | European CRTs from 1970s onwards. Green slightly more yellow than sRGB |
| 1 | P22 (US consumer) | Common US consumer CRT phosphors, 1970s–90s NTSC sets |
| 2 | SMPTE-C / Sony BVM-D / Philips | US broadcast standard and Sony BVM-D reference monitor. Philips European CRTs share identical chromaticities. Most PS1/PS2/N64 era games were mastered on BVM-D |
| 3 | Sony Trinitron | Measured Trinitron phosphor chromaticities. Subtle shift — slightly more saturated green |
| 4 | NTSC 1953 (Illuminant C) | Original FCC NTSC specification. Very wide gamut, especially reds and greens. Illuminant C white (~6774K, slightly warmer than D65). Early 1950s US TV receiver phosphors — games did not target this standard |
| 5 | NTSC 1953 D93 (Japanese) | Same NTSC 1953 primaries with ~9300K Japanese CRT white point. Japan never adopted SMPTE-C. Most relevant for SNES, Mega Drive, Saturn content as it appeared on Japanese consumer hardware |

- **Correction Strength** — blend between original colours (0.0) and fully corrected (1.0). Allows subtle correction without full commitment
- **Display Gamut** — output colour space of your display. sRGB for standard monitors, DCI-P3 Modern for most OLEDs and wide-gamut displays, Rec. 2020 for QD-OLED native gamut

### Interference

Requires `ENABLE_INTERFERENCE=1`. All interference effects run as a single post-process pass applied to the final composited image — after scanlines, mask, glow, halation, grain and HDR pipeline. This is correct because these are signal-level effects (RF pickup, AC mains, antenna reflections) that happen to the video signal before it reaches the display, not to the display itself.

Effects run in this order within the pass: accumulate modulation → wiggle → hum bars → rolling scanlines → ghost.

- **Hum Bar Intensity** — AC mains interference scrolling brightness gradient. Caused by 50/60Hz electrical pickup in poorly shielded CRTs. Positive = dark band scrolls up, negative = bright band. 0.1–0.2 = subtle, 0.5+ = strong
- **Hum Bar Speed** — scroll rate. 50 = 50Hz PAL. 60 = 60Hz NTSC
- **Wiggle Strength** — horizontal UV displacement per scanline row, simulating electromagnetic interference. Three incommensurable sine waves multiplied together (NewPixie approach) create a complex quasi-random waveform. Scaled by resolution — same value produces the same pixel displacement at any resolution. At 4K start around 0.0001–0.0003
- **Wiggle Speed** — how fast the wiggle pattern evolves. Resets every 849 frames to prevent drift
- **Rolling Scanlines Speed** — sine-wave scanline grid at screen-resolution frequency that scrolls vertically, simulating sync instability. Fixed 0.18 amplitude matching NewPixie. Speed=0 disables. Resets every 640 frames
- **Accumulate Modulation** — phosphor afterglow accumulation. Each frame blends `max(prev × modulate, current × 0.96)`. Bright content trails across frames. 0.5–0.7 = subtle trail, 0.9+ = heavy persistence
- **Ghost Strength** — chromatic ghost image displaced slightly from the source, simulating RF reflections in an antenna cable arriving delayed. Each R/G/B channel samples at a fixed small offset plus a tiny animated wobble. Scaled by resolution — at 4K/5K start around 0.005–0.01. NewPixie hardcoded value is 0.15 at 1080p
- **Ghost Speed**
- **Scanline Jitter** — per-scanline vertical displacement in pixel units. Uses a slow per-row hash (`FRAMECOUNT/3`) so it drifts rather than being static. 0.3–0.8 = subtle organic instability, 1.0–2.0 = noticeable. Needs `ENABLE_INTERFERENCE=1`
- **H-Sync Instability** — probabilistic per-row horizontal displacement simulating weak H-sync lock. Two controls: Strength (displacement magnitude, resolution-scaled) and Glitch Rate (probability per row per frame, 0.02 = 2% of rows). Slightly stronger near top of screen. Needs `ENABLE_INTERFERENCE=1`
- **Dot Crawl** — NTSC composite colour subcarrier interference pattern at luma-chroma boundaries. Animated diagonal noise characteristic of 240p composite content. Needs `ENABLE_INTERFERENCE=1`
- **Magnetic Interference** — persistent radial hue rotation around a user-positioned source point, simulating a magnet or speaker near the CRT. Five controls: Strength, Source X/Y position, Radius, and Animation Speed. Needs `ENABLE_INTERFERENCE=1` — speed of the animated wobble on the ghost position. Does not affect the fixed base displacement

### Edge Blur

Simulates CRT aperture falloff — soft darkening and blurring toward screen edges, independent of vignette.

- **Edge Blur Strength** — intensity of the edge blur effect
- **Edge Blur Max Radius** — maximum blur radius at the screen corners (pixels)
- **Edge Blur Falloff** — how quickly the blur builds from centre to edge. Higher = more concentrated at edges

### Tube Diffuse

Requires `ENABLE_TUBE_DIFFUSE=1`. Ambient glow from phosphors scattering through the CRT glass. A heavily blurred copy of the final image composited additively at low opacity. Creates faint warmth proportional to scene brightness — different from halation which halos bright elements. Based on Mega Bezel fullscreen glow concept.

- **Tube Diffuse Strength** — 0.02–0.06 = subtle ambient warmth, 0.15+ = visible
- **Tube Diffuse Gamma** — higher = effect concentrated on brighter content

### Screen Reflection

Requires `ENABLE_SCREEN_REFLECT=1`. Faint blurred self-reflection at screen edges, simulating light bouncing between the thick CRT glass and the tube. Most visible on dark backgrounds with bright content near the edges.

- **Reflection Strength** — 0.02–0.05 = subtle, 0.1+ = visible
- **Reflection Gamma** — concentrates reflection on brighter content
- **Edge Fade** — controls how far inward the reflection extends from screen edges

### Edge Feedback

Requires `ENABLE_EDGE_FEEDBACK=1`. Amplifies CRT edge and peripheral effects by comparing the current pixel against its neighbours from the previous rendered frame. The difference captures accumulated CRT processing — mask transitions, scanline gaps, vignette gradient, geometry warp — and feeds it back as edge enhancement. Most effective with `ENABLE_GEOMETRY=1`. Motion may introduce slight ghosting at high strength values.

- **Edge Feedback Strength** — amplifies luma edges and screen-peripheral CRT effects. Strongest at screen edges and curved geometry areas. 0.1–0.3 = subtle, 0.5+ = strong
- **Chroma Diffusion** — softens colour channels horizontally using the previous frame as reference. 0.3–0.6 = subtle

### Composite Video

Requires `ENABLE_COMPOSITE=1`. Processes luma and chroma independently, simulating the reduced chroma bandwidth of NTSC/PAL composite/RF video. Integrated into the main CRT pass and operates on the correct source frame with proper UV mapping.

- **Chroma Blur Width** — horizontal blur applied to colour channels only. Luma stays sharp while colours bleed. 1.0–2.0 = authentic composite look, 4.0+ = heavy RF degradation
- **Chroma Phase Offset** — horizontal offset of colour channels relative to luma, simulating composite signal delay
- **Luma Sharpness Boost** — compensating unsharp mask on luma only, giving crisp edges alongside soft colour bleed

### Post-Scanline Softening (Scanline Persistence)

A subtle vertical softening pass applied after scanlines, which reduces the harsh aliasing that can appear at scanline edges, particularly with curved geometry. Controlled by `ENABLE_SCANLINE_SOFTEN`.

- **Scanline Soften Strength** — how much vertical blending is applied between scanline rows. 0 = off, 0.5–0.8 = natural CRT persistence feel

### Sharpen
CAS (Contrast Adaptive Sharpening). Restores fine detail softened by pre-blur and the mask passes.

- **Strength** — how strongly detail is recovered. 0.3–0.5 is typical
- **Clamp** — prevents haloing on hard edges. Lower = safer, less risk of ringing

### Motion Sharpening

Requires `ENABLE_MOTION_SHARPEN=1`. A separate CAS sharpening pass that uses the frame-to-frame difference as a motion mask — stronger sharpening is applied to moving regions, static areas receive little or none. Complements BFI by counteracting sample-and-hold blur on moving objects.

- **Motion Sharpen Strength** — overall amplitude. 0.3–0.5 = subtle, 1.0 = strong
- **Motion Threshold** — minimum luma change to count as motion. Raise if grain triggers false sharpening
- **Motion Sharpen Clamp** — prevents haloing, same role as in the main CAS pass

Requires `ENABLE_DECAY=1` for the motion reference frame. Without decay, sharpening is applied uniformly.

### Phosphor Persistence

Requires `ENABLE_PERSISTENCE=1`. Simulates slow phosphor fade — each frame blends slightly with a stored version of the previous frame, creating a subtle trailing afterimage on moving objects.

- **Persistence Strength** — uniform blend across all channels. Used when all per-channel values are zero
- **Persistence Decay Distance** — spatial gaussian decay radius of the stored frame
- **Persistence R / G / B** — per-channel decay rates. Real P22 phosphors decay at different speeds: green persists longest (~2–3ms), red intermediate, blue fastest (~0.5ms). When any per-channel value is non-zero, these override the uniform Persistence Strength. For authentic P22 behaviour: G=0.4, R=0.25, B=0.1

### Anti Burn-In

Two independent systems to prevent static image burn-in during extended play.

- **Phase Shift** — slowly drifts the image position in a sinusoidal pattern. **Period** controls cycle duration (minutes), **Amplitude** controls maximum displacement (pixels)
- **Orbit** — slow circular drift. **Orbit Period** controls cycle duration, **Orbit Radius** controls displacement radius

Both are subtle enough to be imperceptible during normal play.

### Geometry

Requires `ENABLE_GEOMETRY=1`. Screen curvature and zoom simulation.

- **Geometry Mode** — curvature type (off, spherical, cylindrical)
- **Curvature Strength** — how strongly the image is warped
- **Zoom** — compensates for the zoom-out effect of curvature

Note: geometry is implemented as UV remapping in the main CRT pass. Glow and halation are composited through the warp for correct alignment. Use `ENABLE_LIGHT_WARP` for a cheaper alternative when full accuracy is not needed.

### Light Warp

Requires `ENABLE_LIGHT_WARP=1` and `ENABLE_GEOMETRY=0`. A lightweight barrel/pincushion distortion applied to the final image as a post-process — much cheaper than full geometry since no Lanczos reconstruction, glow correction, or multi-pass sampling is involved. The entire scene including scanlines and mask bends with the warp.

- **Warp Strength** — positive = barrel distortion (image curves inward, CRT-like). Negative = pincushion. 0.1–0.3 = subtle CRT curve. 0.5+ = strong
- **Warp Border Colour** — colour of the area outside the warped screen boundary. Black (default) = authentic CRT bezel look
- **Pin Phase** — horizontal scan linearity error based on Sony Megatron: horizontal position of each scanline varies with its vertical position (`uv.x *= 1 + pin_phase * uv.y`). Models real CRT deflection yoke geometry. Positive = pincushion, negative = barrel. Different from radial warp — distorts only horizontally, which is more physically accurate to real CRT raster geometry. Can be used alongside Warp Strength for combined effects

### Corner Rounding

Requires `ENABLE_CORNER_ROUND=1`. Rounded screen mask with optional bezel border shadow, matching the approach used in CRT Guest Advanced.

- **Corner Size** — radius of rounded corners. 0.0 = square. 0.05–0.10 = subtle. 0.15–0.25 = strong consumer TV rounding
- **Border Size** — adds a darkened shadow along all four screen edges independently of corner rounding, simulating the bezel shadow cast by the CRT housing. 0.0 = no border. 0.5–1.0 = subtle edge shadow
- **Border Intensity**
- **Corner Shadow** — sharp darkening at extreme screen corners simulating the shadow cast by the CRT bezel pressing against the tube. Independent of corner rounding geometry. Requires `ENABLE_CORNER_ROUND=1` — power curve applied to the corner/border mask. Higher = sharper, more contrasty edge. Lower = soft gradual transition. 2.0 = default (sharp)

The mask is a luminance multiplier — it darkens toward the edges and corners rather than filling with a flat colour, giving a natural bezel appearance.

### Pipeline (Soop HDR Integration)

Only relevant when using the Soop HDR framework (`PIPELINE=1` or `PIPELINE=2`).

- **Display Peak Brightness (nits)** — peak luminance of your HDR display
- **Shadow Gamma** — gamma of the Reinhard compression shadow region
- **HDR10 Peak Brightness** — for PIPELINE=2 (HDR10 PQ encoding)

---

## Phosphor Decay (BFI System)

Requires `ENABLE_DECAY=1`. This is the most complex part of the shader.

### What it does

Addresses **sample-and-hold** motion blur — the smearing caused by LCD/OLED pixels being held at a fixed value for the entire frame period. The eye's smooth pursuit tracking integrates this static image, producing blur on moving objects.

**Note:** This is software-based and operates by alternating frame content, not by controlling the display backlight. Hardware BFI (ULMB, LightBoost) is more effective. This shader's implementation is the best achievable in post-processing.

### How it differs from hardware BFI

Hardware BFI turns the backlight off between frames — the pixel values are unchanged, only the illumination is gated. Our implementation alternates between a lit frame (`c × litGain`) and a dark frame (`darkFloor`) on consecutive rendered frames. Each frame is still displayed for the full frame period; the darkness comes from the pixel content, not the backlight.

### Decay Method

| Method | Best for | Notes |
|---|---|---|
| Fibonacci | Any pipeline, any fps | Uniform progressive darkening. Most stable |
| Variable MPRT (BB - SDR only) | PIPELINE=0, 120Hz+ | Blur Busters algorithm. Dark pixels decay fast, bright pixels preserved. History frames required |
| BFI - Black Frame Insertion | Any pipeline | Alternates lit/dark frames. Simplest and most effective for motion clarity |

**Pipeline compatibility:**
- Variable MPRT: **PIPELINE=0 only**. On PIPELINE=1/2 highlights remap incorrectly — use BFI instead
- BFI: works on any pipeline, gain applied in linear space for PIPELINE=0 and via Reinhard for PIPELINE=1/2

### Key BFI Settings

**Frames per Decay Cycle** — at 120Hz, keep at 2. Higher values reduce perceived brightness further and at 120Hz produce visible 30-40Hz pulsing.

**Gain vs Blur** — `litGain = frames × gain`. At gain=0.5 with frames=2, `litGain=1.0` — the lit frame outputs the signal unchanged with no clipping. Raise above 0.5 to boost mid-tone brightness at the cost of highlight clipping. If bright areas (sky, bloom) appear grey, reduce gain toward 0.4.

**VRR Dark Frame Floor** — raises the dark frame from pure black. Reduces BFI flicker amplitude under VRR at the cost of some motion clarity. Start at 0.0, raise to 0.05–0.10 if VRR flicker is distracting.

### Experimental BFI Options

**Invert Cycle** — for 240Hz+ only. Inverts the lit/dark ratio: instead of 1 lit + N-1 dark frames, uses N-1 lit + 1 dark. Maintains higher average brightness while retaining some clarity benefit from the single dark frame. At 120Hz causes visible pulsing — do not use.

**BFI Duty Ratio** — skips BFI every N cycles, replacing skipped cycles with passthrough. Reduces flicker at the cost of clarity. The 1:2 setting at 120Hz reduces the effective dark frame rate to 30Hz which may itself be visible as a rhythm.

**Sine BFI** — replaces the hard lit/dark square wave with a smooth cosine gain curve. Reduces the abruptness of transitions. At frames=2 has no practical effect — only meaningful at frames=4+.

**Frametime Spike Suppress** — suppresses BFI output on frames where `CRT_FRAMETIME > CRT_FRAMETIME_EXPECTED × threshold`, outputting passthrough instead. Prevents frametime hitches from causing a bright or dark flash. Default 10.0 (disabled). Set `CRT_FRAMETIME_EXPECTED` to match your display Hz.

**BFI Auto-Resync** — monitors average luminance of lit vs dark frames. If dark frames become unexpectedly bright (phase flip), automatically corrects by 1 frame. May not reliably detect desync in all cases.

**Frame Gen Phase Flip** — for DLSS Frame Generation. With 2-frame BFI, FRAMECOUNT naturally alternates real/generated frames between lit and dark phases. If real frames land on the dark phase (image looks dimmer than expected), enable this to flip.

### BFI at 120Hz — Practical Notes

- **Use frames=2.** This is the only value that produces above-fusion-threshold (60Hz) alternation at 120Hz
- **Lock fps to display Hz.** Under VRR, irregular frame delivery causes the eye to integrate varying lit/dark ratios, producing irregular flicker. Cap fps to 120 (or your display rate) for stable BFI
- **Gain 0.4–0.5.** At gain=0.5 the lit frame is the game's signal unchanged. Bright content (sky, bloom, highlights) will appear at half perceived brightness on average — this is the unavoidable cost of 50% duty cycle BFI on an SDR display
- **BFI and VRR are fundamentally incompatible** for the smoothest results. VRR was designed for motion smoothness; BFI was designed for motion clarity. They oppose each other

### Fibonacci Decay Notes

A simpler progressive darkening that works at any framerate and pipeline. Not true BFI — it gradually darkens the signal across multiple history frames to simulate phosphor persistence decay. Less effective for motion clarity than BFI but flicker-free and easier to use.

- **Stages** — number of history frames used (2–8). More stages = richer trail effect
- **Speed** — how quickly brightness decays
- **Decay Floor** — minimum brightness of decayed frames (0=black, 1=no decay)
- **Highlight Protection** — reduces decay on bright pixels. Default 0.20

---

## Performance Optimisation

The shader includes several preprocessor defines to trade quality for performance:

| Change | Saving | Quality Impact |
|---|---|---|
| `HALATION_RESOLUTION=4` | High | None — halation is low frequency |
| `GLOW_RESOLUTION=2` | High | None — glow is low frequency. **Note:** some games may show a ghost double-image artefact at GLOW_RESOLUTION > 1. Set to 1 if you see this |
| `ENABLE_EDGE_BLUR=0` | Medium | Slight edge softness loss |
| `ENABLE_PREBLUR=0` | Medium | Sharper source, less AA |
| `ENABLE_PERSISTENCE=0` | Low | Remove persistence simulation |
| `ENABLE_DECAY=0` | Medium | Removes all BFI passes |
| `PREBLUR_RESOLUTION=2` | Medium | **Visible quality loss — not recommended** |

---

## Troubleshooting

### Temporal Shimmer on Detailed Textures (Gravel, Fabric)

If fine textures shimmer or alias against the scanline pattern during camera movement, enable `ENABLE_PREBLUR=1` and increase `Pre-Blur Vertical Sigma` (0.3–0.8). Enable **Luma-Only Blur** (default on) to preserve colour saturation. Use **Edge Preservation (Bilateral)** (0.3–0.7) to limit blur to flat areas while keeping object edges sharp. This targets temporal aliasing between high-frequency texture and the scanline grid without softening the overall image.

### Image Degradation or Aliasing on Glow

If you notice aliasing, shimmering, or reduced quality on the glow/halation output, try setting `GLOW_RESOLUTION=1` in the preprocessor definitions. This switches the glow textures to full resolution instead of the default half resolution, which eliminates the quality loss. Expect a moderate performance penalty — the glow passes will cost more GPU time at full resolution.

### Colour Inversion or Blue Tint on Warm Content (Pipeline 0)

Some games output colours outside the standard Rec.709/sRGB gamut to the backbuffer — for example DCI-P3 or BT.2020 primaries. On `PIPELINE=0` the shader assumes sRGB input, which can cause blue channel inversion or warm colour casts on games with wider gamut output.

**How to detect:** Use [Lilium's HDR Analysis](https://github.com/EndlesslyFlowering/ReShade_HDR_shaders) shader. If it shows DCI-P3 or BT.2020 coverage above ~10% with the CRT shader active, this is likely the cause.

**Fix:** Switch to `PIPELINE=2` in the preprocessor definitions. The HDR10 soop path is colour-space agnostic and handles wide-gamut content correctly without the matrix conversion issues that cause inversion on Pipeline 0. Example game where this applies: *Keeper*.

---

## Known Issues

### ReShade 6.73+ BFI Flicker

ReShade 6.73 introduced a reworked DXGI hook system ("proxy classes") that changed when during the presentation cycle the shader executes. This appears to shift the relationship between `FRAMECOUNT` and the display's VSync signal, effectively changing which frames are lit and which are dark in the BFI cycle.

**Observed symptoms:**
- At locked 120fps in some games (e.g. Hades II), BFI flicker is significantly worse on 6.73 than on 6.62
- 118fps locked may produce stable BFI while 120fps locked does not — the slight fps offset may accidentally produce a phase relationship that works with the changed hook timing
- The issue is not reproducible across all games or all systems

**Workarounds:**
- Use ReShade 6.62 if BFI is a priority
- Toggle **Frame Gen Phase Flip** in the shader UI — this flips the BFI phase by 1 frame and may resolve the mismatch caused by the hook timing change
- Cap fps slightly below the display refresh rate (e.g. 118 on a 120Hz display)

**Root cause:** `FRAMECOUNT` is an integer that increments once per frame regardless of display timing. ReShade 6.73's DXGI changes may have introduced a one-frame offset in when the technique executes relative to the display's scan-out, effectively pre-shifting the phase of the BFI cycle.

### ReShade 6.73+ General

The same DXGI hook rework that affects BFI may also affect:
- Frame timing precision (CRT_FRAMETIME accuracy)
- The Frametime Spike Suppress feature (if frametime reporting changed)

No shader-level fix is possible for these issues beyond the workarounds noted above.

### Variable MPRT on PIPELINE=1/2

Using Variable MPRT (Blur Busters method) with `PIPELINE=1` or `PIPELINE=2` causes incorrect highlight remapping. The shader displays a red tint as a warning. Use BFI method instead on HDR pipelines.

### BFI with Frame Generation

- **DLSS Frame Generation:** FRAMECOUNT increments for generated frames. BFI naturally alternates real/generated frames between lit and dark phases — this is actually correct behaviour. Use Frame Gen Phase Flip if the phase is inverted
- **Lossless Scaling (LSFG):** Runs outside ReShade, FRAMECOUNT does not see generated frames. LSFG duplicates the last ReShade output frame — if that was a dark frame, the duplicated frame is also dark. BFI is not meaningfully compatible with LSFG
- **Nvidia Smooth Motion:** Same as LSFG — runs outside ReShade, not compatible. Also affects `ENABLE_INTERLACE` — generated frames are not seen by FRAMECOUNT, causing the interlace field pattern to become irregular (drifting multi-scanline pattern). Interlace is not compatible with any frame generation that runs outside ReShade

### BFI Desync in Some Games

Some games (notably older UE4 titles) produce occasional frame timing anomalies that flip the BFI phase permanently, causing sustained heavy flicker. The Auto-Resync experimental option attempts to detect and correct this but may not work reliably in all cases. Reloading the shader (click the effect name in ReShade) resets FRAMECOUNT and resolves the desync.

---

## Quick Start Presets

### Subtle CRT (good starting point)
```
ENABLE_DECAY=0
Mask Type: 5 (slot mask)
Mask Strength: 0.3
Scanline Strength: 0.3
Glow Strength: 0.1
Halation Strength: 0.3
Grain Intensity: 0.15
Vignette Strength: 0.08
```

### BFI for Motion Clarity (120Hz display, SDR game)
```
ENABLE_DECAY=1
CRT_FRAMETIME_EXPECTED=8.33
Decay Method: BFI
Frames per Cycle: 2
Gain vs Blur: 0.5
VRR Dark Frame Floor: 0.0 (raise to 0.05–0.10 if VRR flicker is distracting)
```

### HDR Pipeline
```
PIPELINE=1
ENABLE_DECAY=1
Decay Method: BFI (Variable MPRT will show red tint warning on PIPELINE=1)
```

---

## Understanding the BFI Brightness Trade-off

With `frames=2` and `gain=0.5`, the lit frame outputs the game signal unchanged (`litGain=1.0`). The dark frame outputs near-black. The eye integrates both frames and perceives roughly 50% of the original average brightness — this is the unavoidable photometric cost of 50% duty cycle BFI on a display bounded by its peak luminance.

For content with headroom (midtones and below), raising gain above 0.5 partially compensates by boosting the lit frame. For content near peak brightness (sky, clouds, bloom), no compensation is possible — the lit frame is already at the display ceiling. This manifests as bright areas appearing grey compared to no-BFI.

Hardware BFI (ULMB, LightBoost) addresses this by boosting the backlight intensity during the lit window — effectively multiplying peak luminance by the inverse of the duty cycle. Software BFI cannot do this.

---

## Games Tested with BFI / BB — Working Great

Sifu, Crash Bandicoot, Cuphead, Hades 1 & 2, Hollow Knight, Planet of Lana 2, Legacy of Kain: Defiance Remaster, Moons of Madness, Cocoon, Prince of Persia: The Lost Crown, The Rogue: Prince of Persia, Stray, Baja: Edge of Control, Ori and the Blind Forest, Jotun, Neva, Gris, Layers of Fear 2, Untitled Goose Game, Dead Cells, FAR: Lone Sails, Mirror's Edge Catalyst, Tony Hawk's Pro Skater 1+2, Return to Monkey Island, Obduction, Clive Barker's Undying, Rime.

---

## Credits

### License

CRT-Standalone is licensed under **GNU General Public License v2 or later (GPL v2+)**. This is required for compatibility with CRT Guest Advanced (GPL v2+) from which the corner rounding function is derived. All other incorporated components (Megatron/MIT, NewPixie/MIT+PD, Variable MPRT/MIT, CAS/MIT) are compatible with GPL v2+.

See the `LICENSE` file for full terms.

---

**Reference shaders consulted for implementation guidance:**

- **CRT Royale** (Timothy Lottes) — scanline beam model, phosphor persistence architecture
- **CRT Guest Advanced** (guest.r) — corner rounding function, hum bars implementation, scanline beam shape controls, afterglow approach
- **Sony Megatron CRT** (MajorPainTheCactus) — Bezier brightness/contrast/saturation in Yxy space, pin phase horizontal linearity distortion, scanline compositing approach
- **NewPixie** (iktah) — interference effects: wiggle triple-sine, rolling scanlines (scanroll), ghost image compositing formula, accumulate modulation pattern

**Algorithms and techniques:**

- **Variable MPRT** — Blur Busters algorithm (Mark Rejhon, Timothy Lottes — MIT licence)
- **CAS Sharpening** — AMD Contrast Adaptive Sharpening
- **Film grain** — Poisson variance approach inspired by METEOR (Marty McModding)
- **Mask moiré dither** — Haeberli & Segal (1990) display simulation
- **Soop HDR sandwich** — Soop framework integration
- **BFI** — custom implementation
