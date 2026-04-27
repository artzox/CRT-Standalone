# CRT-Standalone Shader — User Guide

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

### Resolution Defines

| Define | Default | Description |
|---|---|---|
| `HALATION_RESOLUTION` | 4 | Halation blur resolution divisor. 4=quarter res (recommended), 2=half, 1=full |
| `GLOW_RESOLUTION` | 2 | Glow blur resolution divisor. 2=half res (recommended), 1=full |
| `PREBLUR_RESOLUTION` | 1 | Pre-blur resolution. Keep at 1 — lower values visibly degrade quality |

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

- **Mask Type** — choose between shadow mask, aperture grille, slot mask variants
- **Mask Strength** — how visible the pattern is. 0.3–0.6 is typical
- **Mask Boost** — brightens the lit areas of the mask to compensate for the darkening effect

### Scanlines
- **Scanline Strength** — depth of dark scanlines between phosphor rows
- **Scanline Sigma** — softness of the scanline edge
- **Per-channel attack** — how much each channel contributes to the scanline modulation

### Beam Modulation
Controls how beam width varies with signal level — brighter pixels produce wider, softer beams.

- **Min/Max Sigma** — beam width range from dark to bright pixels

### Glow
A wide soft bloom applied to bright image areas.

- **Threshold** — luminance above which glow starts
- **Strength** — how bright the glow is
- **H/V Radius** — how far glow spreads horizontally and vertically
- **Sigma** — falloff shape within the radius
- **H Mix** — blend between horizontal and vertical glow contributions
- **Balance** — between glow contributing additively vs multiplicatively

### Halation
Simulates light scattering behind the CRT glass faceplate — a soft warm glow around bright elements.

- **Strength** — overall halation intensity
- **Radius** — how far halation spreads (in pixels at quarter-resolution)
- **Sigma** — falloff within the radius
- **Saturation** — colour saturation of the halation glow
- **Threshold** — luminance gate — only bright pixels produce halation
- **Anisotropy** — horizontal vs vertical spread ratio. >1 = wider horizontal spread (realistic for vertical shadow mask stripes)

### Chromatic Aberration
Radial colour fringing simulating glass lens dispersion. Zero at screen centre, maximum at corners.

- **CA Strength** — magnitude. 0.002–0.005 = subtle, 0.01+ = strong
- **CA Falloff** — how the CA builds toward edges. 1=linear, 2=quadratic (default, physically accurate), 3+=concentrates at corners

### Convergence
Simulates CRT electron gun misregistration — independent vertical offset per R/G/B channel. Different from CA (which is radial/lens-based). Both can be used simultaneously.

### Vignette
Edge darkening.

- **Shape** — Circular/Elliptical (default, original oval) or Rectangular (CRT-authentic H×V falloff with naturally darker corners)
- **H Power** — falloff speed horizontally. In Circular mode, controls overall power
- **V Power** — falloff speed vertically. No effect in Circular mode. Keep 1.0–2.5 in Rectangular mode to avoid a sliver effect
- **Strength** — overall vignette intensity
- **HDR Protection Threshold** — prevents vignette from crushing bright highlights

### Film Grain
- **Animate** — grain changes each frame (recommended)
- **Colour** — independent per-channel grain (film-like). Off = monochrome grain
- **Intensity** — grain amplitude. 0.15–0.25 is typical. Higher values darken bright areas due to Poisson variance rolloff
- **Shadows** — minimum grain level in shadow areas
- **Grain Size** — diffusion spread of grain clusters. 0.2 = fine (default). Higher = larger organic clumps

### Sharpen
CAS (Contrast Adaptive Sharpening).

- **Strength** — how strongly detail is recovered
- **Clamp** — prevents haloing on hard edges. Lower = safer

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
| `GLOW_RESOLUTION=2` | High | None — glow is low frequency |
| `ENABLE_EDGE_BLUR=0` | Medium | Slight edge softness loss |
| `ENABLE_PREBLUR=0` | Medium | Sharper source, less AA |
| `ENABLE_PERSISTENCE=0` | Low | Remove persistence simulation |
| `ENABLE_DECAY=0` | Medium | Removes all BFI passes |
| `PREBLUR_RESOLUTION=2` | Medium | **Visible quality loss — not recommended** |

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
- **Nvidia Smooth Motion:** Same as LSFG — runs outside ReShade, not compatible

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

## Credits

- BFI algorithm: custom implementation
- Variable MPRT: Blur Busters algorithm (Mark Rejhon, Timothy Lottes — MIT licence)
- CAS sharpening: AMD Contrast Adaptive Sharpening
- Film grain: Poisson variance approach inspired by METEOR (Marty McModding)
- Soop HDR sandwich integration: Soop framework
- Halation, scanlines, mask: original implementation
