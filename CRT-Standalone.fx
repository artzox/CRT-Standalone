#include "ReShade.fxh"

/*
    CRT-Standalone.fx
    Self-contained CRT shader. Features:
    - Pre-blur (H+V) before mask/scanlines, matching Guest Advanced SIZEH/SIZEV
    - Aperture grille mask (resolution-aware, anti-aliased)
    - Megatron cubic Bezier per-channel beam
    - Beam spot size modulation
    - Gamma-correct scanlines
    - Megatron Bezier brightness/contrast/saturation (Yxy space)
    - Brightboost (dark/bright split)
    - Phosphor glow (luminance-weighted, post-scanline)
    - Film grain (Marty METEOR digital sensor noise)

    Preprocessor toggles (zero runtime cost when disabled):
      ENABLE_GAMMA_CORRECT   1/0  (default 1)
      ENABLE_BEAM_MODULATION 1/0  (default 1)
      ENABLE_MASK            1/0  (default 1)
*/

// ============================================================
// Preprocessor toggles
// Signal chain order: Pre-Blur -> Mask -> Scanlines -> Gamma ->
// Brightness -> Halation -> Convergence -> Vignette -> Edge Blur ->
// Film Grain -> Anti Burn-In
// ============================================================

// Pre-Blur
#ifndef ENABLE_PREBLUR
    #define ENABLE_PREBLUR 1
#endif

// Mask
#ifndef ENABLE_MASK
    #define ENABLE_MASK 1
#endif

// Scanlines
#ifndef ENABLE_GAMMA_CORRECT
    #define ENABLE_GAMMA_CORRECT 1
#endif
#ifndef ENABLE_BEAM_MODULATION
    #define ENABLE_BEAM_MODULATION 1
#endif

// Glow loop caps -- compiler unrolls fixed-count loops, ~20-30% faster than dynamic
// Set to match your maximum UI slider values
#ifndef GLOW_H_MAX_RADIUS
    #define GLOW_H_MAX_RADIUS 16
#endif
#ifndef GLOW_V_MAX_RADIUS
    #define GLOW_V_MAX_RADIUS 8
#endif

// Halation
#ifndef ENABLE_HALATION
    #define ENABLE_HALATION 1
#endif
// Halation resolution: 4=quarter res (cheapest), 2=half res, 1=full res
#ifndef HALATION_RESOLUTION
    #define HALATION_RESOLUTION 4
#endif

// Pre-blur resolution divisor.
// 1 = full resolution (default). Some games benefit from keeping this at 1
// as the preblur acts as a mild AA pass when run at native resolution.
// 2 = half resolution (cheaper but visible quality loss on fine detail).
#ifndef PREBLUR_RESOLUTION
    #define PREBLUR_RESOLUTION 1
#endif

// Glow blur resolution divisor. Glow is a wide soft effect -- running at
// reduced resolution is perceptually indistinguishable and saves significantly.
// 1 = full resolution. 2 = half (recommended). 4 = quarter.
//
// NOTE: Some games (e.g. Cuphead) may show a ghost double-image or mini-screen
// artefact when GLOW_RESOLUTION > 1. This is a game-specific interaction with
// how the glow texture is composited. If you see this, set GLOW_RESOLUTION=1.
#ifndef GLOW_RESOLUTION
    #define GLOW_RESOLUTION 2
#endif

// Edge Feedback: cross-frame CRT edge and peripheral enhancement.
// Samples previous frame backbuffer as neighbour reference, amplifying
// differences caused by CRT processing (mask, scanlines, vignette, geometry).
// Most effective with ENABLE_GEOMETRY=1. 1 = enabled, 0 = disabled (default)
#ifndef ENABLE_EDGE_FEEDBACK
    #define ENABLE_EDGE_FEEDBACK 0
#endif

// Noise floor: faint fixed-pattern thermal noise on dark areas.
// Simulates CRT electronics thermal noise, distinct from signal-dependent grain.
// 1 = enabled, 0 = disabled (default)
#ifndef ENABLE_NOISE_FLOOR
    #define ENABLE_NOISE_FLOOR 0
#endif

// Tube diffuse: ambient glow from screen phosphors scattering through the glass.
// 1 = enabled, 0 = disabled (default)
#ifndef ENABLE_TUBE_DIFFUSE
    #define ENABLE_TUBE_DIFFUSE 0
#endif

// Composite video simulation: Y/C separation with independent luma/chroma bandwidth.
// 1 = enabled, 0 = disabled (default)
#ifndef ENABLE_COMPOSITE
    #define ENABLE_COMPOSITE 0
#endif

// Screen reflection: faint blurred self-reflection at screen edges.
// Simulates light bouncing between the thick CRT glass and the tube.
// 1 = enabled, 0 = disabled (default)
#ifndef ENABLE_SCREEN_REFLECT
    #define ENABLE_SCREEN_REFLECT 0
#endif

// Tube diffuse: ambient phosphor scatter glow through the CRT glass.
// 1 = enabled, 0 = disabled (default)
// Interference: wiggle, rolling scanlines, hum bars, ghosting, accumulation.
// All are signal-level effects applied as a post-process on the final image.
// Simulates RF/magnetic interference on a CRT signal.
// 1 = enabled, 0 = disabled (default)
#ifndef ENABLE_INTERFERENCE
    #define ENABLE_INTERFERENCE 0
#endif

// Scanline reference height for resolution-independent scanline width.
// When set, crt_scanline_width is automatically scaled so scanlines look
// identical regardless of the game's render resolution.
//
// Set this to your display's native vertical resolution:
//   4K display:  SCANLINE_REFERENCE_HEIGHT = 2160
//   5K display:  SCANLINE_REFERENCE_HEIGHT = 2880
//   1440p:       SCANLINE_REFERENCE_HEIGHT = 1440
//   1080p:       SCANLINE_REFERENCE_HEIGHT = 1080
//
// 0 = disabled (default). Existing behaviour -- scanline width is in raw
//     pixels at render resolution. Existing presets are unaffected.
#ifndef SCANLINE_REFERENCE_HEIGHT
    #define SCANLINE_REFERENCE_HEIGHT 0
#endif

// Lightweight barrel/pincushion warp pass.
// A cheap post-process UV distortion applied to the final image.
// Only active when ENABLE_GEOMETRY=0 -- use full geometry for accurate warp.
// 1 = enabled, 0 = disabled (default).
#ifndef ENABLE_LIGHT_WARP
    #define ENABLE_LIGHT_WARP 0
#endif

// Interlaced scanline phase pass.
// Offsets the scanline grid by half a line every other frame, simulating
// real CRT interlaced mode. Most visible at high framerates with BFI.
// 1 = enabled, 0 = disabled (default).
#ifndef ENABLE_INTERLACE
    #define ENABLE_INTERLACE 0
#endif

// Corner rounding / bezel pass.
// Applies a rounded screen mask with optional edge darkening.
// 1 = enabled, 0 = disabled (default).
#ifndef ENABLE_CORNER_ROUND
    #define ENABLE_CORNER_ROUND 0
#endif


// Edge Blur
#ifndef ENABLE_EDGE_BLUR
    #define ENABLE_EDGE_BLUR 1
#endif

// Chromatic aberration (radial colour fringing)
#ifndef ENABLE_CA
    #define ENABLE_CA 1
#endif

// Convergence error simulation (per-channel vertical offset)
#ifndef ENABLE_CONVERGENCE
    #define ENABLE_CONVERGENCE 1
#endif

// Vignette (edge darkening)
#ifndef ENABLE_VIGNETTE
    #define ENABLE_VIGNETTE 1
#endif

// Film grain
#ifndef ENABLE_GRAIN
    #define ENABLE_GRAIN 1
#endif
// Post-scanline vertical softening (fixes scanline-edge aliasing on curved geometry)
#ifndef ENABLE_SCANLINE_SOFTEN
    #define ENABLE_SCANLINE_SOFTEN 1
#endif
// Contrast-adaptive sharpening (restores detail softened by pre-blur/scanlines)
#ifndef ENABLE_SHARPEN
    #define ENABLE_SHARPEN 1
#endif

// Motion-adaptive sharpening: uses frame difference between current and previous
// frame to modulate CAS sharpening strength -- stronger in moving regions,
// lighter in static areas. Complements BFI by counteracting sample-and-hold
// blurring on moving objects. Off by default; enable only alongside ENABLE_DECAY.
#ifndef ENABLE_MOTION_SHARPEN
    #define ENABLE_MOTION_SHARPEN 0
#endif

// Reconstruction filter for Pre-Blur passes and geometry warp sampling.
// Used when sampling the backbuffer at non-integer (warped) positions.
// Has no effect on halation/glow blur kernels -- those stay Gaussian.
//
// PREBLUR_FILTER:
//   0 = Lanczos2  (4x4=16 taps, default). Good sharpness, minimal ringing.
//   1 = Lanczos3  (6x6=36 taps). Sharper, ~2x cost. Best for geometry warp.
//   2 = Catmull-Rom (4x4=16 taps). Bicubic spline. Slightly crisper than
//       Lanczos2 on high-contrast edges (scanlines, mask), less overshoot.
//       Same cost as Lanczos2. Good alternative for geometry.
#ifndef PREBLUR_FILTER
    #define PREBLUR_FILTER 0
#endif

// Kept for backwards compatibility -- PREBLUR_FILTER=1 is equivalent
#ifndef PREBLUR_LANCZOS_TAPS
    #define PREBLUR_LANCZOS_TAPS 2
#endif
// Phosphor persistence simulation (within-frame asymmetric vertical blur)
#ifndef ENABLE_PERSISTENCE
    #define ENABLE_PERSISTENCE 1
#endif

// Fibonacci-weighted exponential phosphor decay (BFI-style motion clarity)
// Based on CRT Dusha by Maxim Lapounov (MIT)
// Requires high framerate (120fps+) for best results -- visible flicker at 60fps
// 0 = disabled (default), 1 = enabled
#ifndef ENABLE_DECAY
    #define ENABLE_DECAY 0
#endif

// Anti Burn-In
#ifndef ENABLE_BURNIN_PHASE
    #define ENABLE_BURNIN_PHASE 1
#endif
#ifndef ENABLE_BURNIN_ORBIT
    #define ENABLE_BURNIN_ORBIT 1
#endif

// Pipeline selection -- controls Soop sandwich integration
// 0 = No Soop (default): signal passes through unmodified at boundaries
// 1 = Soop scRGB: Reinhard compression at start, InvReinhard at end
// 2 = Soop HDR10: PQ decode + Reinhard at start, InvReinhard + PQ encode at end
#ifndef PIPELINE
    #define PIPELINE 0
#endif

// Frame generation phase offset.
// With DLSS FG, FRAMECOUNT increments for both real and generated frames.
// With 2-frame BFI the cycle already alternates correctly -- real frames land
// on one parity, generated frames on the other. If real frames land on the
// dark phase instead of the lit phase, set this to 1 to flip.
// 0 = default, 1 = flip phase by one frame.
// LSFG / Nvidia Smooth Motion: leave at 0, they run outside ReShade.
#ifndef FRAMEGEN_PHASE_OFFSET
    #define FRAMEGEN_PHASE_OFFSET 0
#endif

// Expected frame period in milliseconds for spike detection.
// Set to match your target refresh rate: 8.33=120Hz, 6.94=144Hz, 6.06=165Hz
#ifndef CRT_FRAMETIME_EXPECTED
    #define CRT_FRAMETIME_EXPECTED 8.33
#endif

// Linear HDR input: controls BCS path, independent of PIPELINE setting
// 0 = XYZ/Yxy path (perceptually correct, works for Soop sandwich and SDR)
// 1 = linear RGB path (for raw scRGB without any Soop compression)
#ifndef LINEAR_HDR_INPUT
    #define LINEAR_HDR_INPUT 0
#endif

// BCS gamut handling for XYZ/Yxy path (LINEAR_HDR_INPUT=0):
// 0 = soft gamut compression (default)
// 1 = hard clamp to [0,1]
#ifndef BCS_GAMUT_CLAMP
    #define BCS_GAMUT_CLAMP 0
#endif

// Phosphor colour profile correction
// 0 = disabled (passthrough, default)
// 1 = enabled (apply CRT profile + display gamut matrices)
#ifndef ENABLE_PHOSPHOR
    #define ENABLE_PHOSPHOR 1
#endif

// Screen geometry (barrel distortion) -- final pass UV warp
// 0 = disabled (flat, default)
// 1 = enabled
#ifndef ENABLE_GEOMETRY
    #define ENABLE_GEOMETRY 0
#endif

// Peak brightness of your display in nits, used when LINEAR_HDR_INPUT=1.
// Only affects BCS operations -- passthrough is unaffected when BCS is at zero.
// Sony A95L 77" = 1400 nits. Set to your display's actual peak.
// Internally converted to scRGB units (nits / 80).
#ifndef LINEAR_HDR_PEAK_NITS
    #define LINEAR_HDR_PEAK_NITS 1400
#endif

// System uniforms -- always present regardless of feature flags
uniform uint  FRAMECOUNT    < source = "framecount"; >;
uniform float CRT_TIMER     < source = "timer"; >;       // milliseconds since start
uniform float CRT_FRAMETIME < source = "frametime"; >;   // actual ms elapsed this frame

// ============================================================
// Uniforms -- Pre-blur (equivalent to Guest SIZEH/SIZEV/SIGMA)
// ============================================================

#if ENABLE_PREBLUR
uniform float crt_preblur_h_sigma <
    ui_type = "drag"; ui_label = "Pre-Blur Horizontal Sigma";
    ui_category = "Pre-Blur";
    ui_tooltip = "Gaussian sigma for horizontal pre-blur applied before mask and scanlines.\nEquivalent to Guest Advanced SIGMA_H. Blends pixels horizontally before CRT processing.\n0.0 = disabled at runtime. Set ENABLE_PREBLUR=0 in preprocessor to remove passes entirely.";
    ui_min = 0.0; ui_max = 6.0; ui_step = 0.05;
> = 0.0;

uniform float crt_preblur_h_radius <
    ui_type = "drag"; ui_label = "Pre-Blur Horizontal Radius";
    ui_category = "Pre-Blur";
    ui_tooltip = "Tap radius for horizontal pre-blur. Equivalent to Guest SIZEH.\nHigher = wider blend but more expensive.";
    ui_min = 1.0; ui_max = 32.0; ui_step = 1.0;
> = 6.0;

uniform float crt_preblur_v_sigma <
    ui_type = "drag"; ui_label = "Pre-Blur Vertical Sigma";
    ui_category = "Pre-Blur";
    ui_tooltip = "Gaussian sigma for vertical pre-blur. Equivalent to Guest SIGMA_V.\n0.0 = disabled.";
    ui_min = 0.0; ui_max = 6.0; ui_step = 0.05;
> = 0.0;

uniform float crt_preblur_v_radius <
    ui_type = "drag"; ui_label = "Pre-Blur Vertical Radius";
    ui_category = "Pre-Blur";
    ui_tooltip = "Tap radius for vertical pre-blur. Equivalent to Guest SIZEV.";
    ui_min = 1.0; ui_max = 16.0; ui_step = 1.0;
> = 6.0;

#endif // ENABLE_PREBLUR

// ============================================================
// Uniforms -- Composite Video
// ============================================================

#if ENABLE_COMPOSITE
uniform float crt_composite_chroma_blur <
    ui_type = "drag"; ui_label = "Chroma Blur Width";
    ui_category = "Composite Video";
    ui_tooltip = "Horizontal blur applied to colour channels independently of luma.\n"
                 "Models NTSC/PAL reduced chroma bandwidth (~1.5MHz vs 4MHz luma).\n"
                 "Gives soft-colours-sharp-edges composite look.\n"
                 "At 4K: 1.0 = ~2px blur. 3.0 = ~6px. 5.0 = ~10px colour bleed.\n"
                 "0.0 = disabled. 1.0-2.0 = authentic. 4.0+ = heavy RF degradation.";
    ui_min = 0.0; ui_max = 8.0; ui_step = 0.25;
> = 0.0;

uniform float crt_composite_chroma_phase <
    ui_type = "drag"; ui_label = "Chroma Phase Offset";
    ui_category = "Composite Video";
    ui_tooltip = "Horizontal offset of the chroma channels relative to luma.\n"
                 "On real composite video the colour signal could arrive slightly\n"
                 "delayed, causing a visible colour fringe offset from the edges.\n"
                 "0.0 = no offset (default). Positive = colour shifts right.";
    ui_min = -3.0; ui_max = 3.0; ui_step = 0.1;
> = 0.0;

uniform float crt_composite_luma_sharpen <
    ui_type = "drag"; ui_label = "Luma Sharpness Boost";
    ui_category = "Composite Video";
    ui_tooltip = "Compensates for the overall signal softness by boosting luma\n"
                 "edge contrast. Combined with chroma blur gives the authentic\n"
                 "composite look: crisp edges with colour bleed.\n"
                 "0.0 = disabled. 0.1-0.3 = subtle. 0.5+ = strong.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;
#endif // ENABLE_COMPOSITE

// ============================================================
// Uniforms -- Post-Scanline Softening
// ============================================================

#if ENABLE_SCANLINE_SOFTEN
uniform float crt_soften_strength <
    ui_type = "drag"; ui_label = "Scanline Soften Strength";
    ui_category = "Post-Scanline Softening";
    ui_tooltip = "Subtle vertical gaussian applied after scanlines to smooth\n"
                 "staircase aliasing where curved geometry crosses scanline gaps.\n"
                 "Keep low -- 0.3-0.6 is enough. Higher loses scanline definition.\n"
                 "Set ENABLE_SCANLINE_SOFTEN=0 to remove pass entirely.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.4;
#endif

// ============================================================
// Uniforms -- Sharpening
// ============================================================

#if ENABLE_SHARPEN
uniform float crt_sharpen_strength <
    ui_type = "drag"; ui_label = "Sharpen Strength";
    ui_category = "Sharpening";
    ui_tooltip = "Contrast-adaptive sharpening to restore edge detail softened\n"
                 "by pre-blur and scanlines. Sharpens edges, not noise.\n"
                 "0.3-0.5 = subtle, 0.8-1.0 = strong.\n"
                 "Set ENABLE_SHARPEN=0 to remove pass entirely.";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 0.0;

uniform float crt_sharpen_clamp <
    ui_type = "drag"; ui_label = "Sharpen Clamp";
    ui_category = "Sharpening";
    ui_tooltip = "Maximum sharpening per pixel. Prevents over-sharpening on fine detail.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.05;
#endif

#if ENABLE_MOTION_SHARPEN
uniform float crt_msharpen_strength <
    ui_type = "drag"; ui_label = "Motion Sharpen Strength";
    ui_category = "Motion Sharpening";
    ui_tooltip = "Overall strength of the motion-adaptive sharpening pass.\n"
                 "Applied on top of the standard CAS sharpening.\n"
                 "Modulated per-pixel by motion magnitude -- static areas\n"
                 "receive little or no sharpening, moving areas receive more.\n"
                 "0.0 = disabled. 0.3-0.5 = subtle. 1.0 = strong.\n"
                 "Best used with BFI enabled (ENABLE_DECAY=1).";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float crt_msharpen_motion_threshold <
    ui_type = "drag"; ui_label = "Motion Threshold";
    ui_category = "Motion Sharpening";
    ui_tooltip = "Minimum frame-to-frame luma difference to be considered motion.\n"
                 "Below this threshold a pixel is treated as static and receives\n"
                 "no additional sharpening. Prevents noise from triggering sharpening\n"
                 "on visually stable areas.\n"
                 "0.01 = very sensitive (catches subtle motion).\n"
                 "0.05 = moderate (ignores noise, catches clear motion).\n"
                 "0.10 = only sharp on fast or high-contrast motion.";
    ui_min = 0.005; ui_max = 0.2; ui_step = 0.005;
> = 0.03;

uniform float crt_msharpen_clamp <
    ui_type = "drag"; ui_label = "Motion Sharpen Clamp";
    ui_category = "Motion Sharpening";
    ui_tooltip = "Limits maximum sharpening weight to prevent haloing on hard edges.\n"
                 "Lower = more conservative, less risk of overshoot.\n"
                 "Matches the role of Sharpen Clamp in the main CAS pass.";
    ui_min = 0.01; ui_max = 0.5; ui_step = 0.01;
> = 0.1;
#endif

// ============================================================
// Uniforms -- Phosphor Persistence
// ============================================================

#if ENABLE_PERSISTENCE
uniform float crt_persistence_r <
    ui_type = "drag"; ui_label = "Persistence R";
    ui_category = "Phosphor Persistence";
    ui_tooltip = "Persistence strength for the red channel.\n"
                 "Real P22 phosphors decay at different rates per colour:\n"
                 "Green persists longest, red intermediate, blue fastest.\n"
                 "Set all three equal for uniform decay (original behaviour).";
    ui_min = 0.0; ui_max = 0.99; ui_step = 0.01;
> = 0.0;

uniform float crt_persistence_g <
    ui_type = "drag"; ui_label = "Persistence G";
    ui_category = "Phosphor Persistence";
    ui_tooltip = "Persistence strength for the green channel.\n"
                 "Green phosphors have the longest decay time (~2-3ms on P22).\n"
                 "Set higher than R and B for authentic phosphor physics.";
    ui_min = 0.0; ui_max = 0.99; ui_step = 0.01;
> = 0.0;

uniform float crt_persistence_b <
    ui_type = "drag"; ui_label = "Persistence B";
    ui_category = "Phosphor Persistence";
    ui_tooltip = "Persistence strength for the blue channel.\n"
                 "Blue phosphors have the fastest decay (~0.5ms on P22).\n"
                 "Set lower than R and G for authentic phosphor physics.";
    ui_min = 0.0; ui_max = 0.99; ui_step = 0.01;
> = 0.0;

uniform float crt_persistence_strength <
    ui_type = "drag"; ui_label = "Persistence Strength";
    ui_category = "Phosphor Persistence";
    ui_tooltip = "Simulates phosphor decay within a single frame by blending a\n"
                 "downward-offset copy of the image. Mimics the CRT beam sweep\n"
                 "leaving a fading trail below each scanline.\n"
                 "Keep very low -- 0.05-0.15 for subtle CRT character.\n"
                 "Higher values look like ghosting.\n"
                 "Set ENABLE_PERSISTENCE=0 to remove pass entirely.";
    ui_min = 0.0; ui_max = 0.05; ui_step = 0.001;
> = 0.0;
uniform float crt_persistence_decay <
    ui_type = "drag"; ui_label = "Persistence Decay Distance (pixels)";
    ui_category = "Phosphor Persistence";
    ui_tooltip = "How many pixels below each point the phosphor trail extends.\n"
                 "Matches your scanline width for most natural result.";
    ui_min = 1.0; ui_max = 16.0; ui_step = 0.5;
> = 4.0;
#endif

// ============================================================
// Uniforms -- Mask
// ============================================================

uniform float crt_triad_width <
    ui_type = "drag"; ui_label = "Triad Width (pixels at 4K ref)";
    ui_category = "Mask";
    ui_tooltip = "Width of one RGB triad in screen pixels at 4K reference resolution.\nHas no effect when ENABLE_MASK=0.";
    ui_min = 0.5; ui_max = 8.0; ui_step = 0.05;
> = 1.5;

uniform float crt_mask_strength <
    ui_type = "drag"; ui_label = "Mask Strength";
    ui_category = "Mask";
    ui_tooltip = "How dark the gaps between phosphors are.\nSet ENABLE_MASK=0 in preprocessor to fully disable.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float crt_mask_boost <
    ui_type = "drag"; ui_label = "Mask Boost";
    ui_category = "Mask";
    ui_tooltip = "Brightness compensation for mask darkening. Set to 1.0 with mask disabled.";
    ui_min = 1.0; ui_max = 2.0; ui_step = 0.01;
> = 1.2;

uniform float crt_phosphor_sharpness <
    ui_type = "drag"; ui_label = "Phosphor Sharpness";
    ui_category = "Mask";
    ui_min = 0.5; ui_max = 8.0; ui_step = 0.1;
> = 2.0;

uniform float3 crt_phosphor_colour <
    ui_type = "color"; ui_label = "Phosphor Colour Temperature";
    ui_category = "Mask";
    ui_tooltip = "(1,1,1)=neutral, (1.02,1,0.97)=P22 warm.";
> = float3(1.0, 1.0, 1.0);

uniform float crt_phosphor_dot <
    ui_type = "drag"; ui_label = "Phosphor Dot Structure";
    ui_category = "Mask";
    ui_tooltip = "Subtle procedural luminance variation between individual phosphor\n"
                 "dots/stripes, simulating manufacturing imperfections in the\n"
                 "phosphor coating. Almost invisible individually but adds texture\n"
                 "and organic feel at high magnification.\n"
                 "0.0 = disabled (default). 0.02-0.05 = authentic subtle texture.";
    ui_min = 0.0; ui_max = 0.15; ui_step = 0.005;
> = 0.0;

uniform int crt_mask_type <
    ui_type = "combo"; ui_label = "Mask Type";
    ui_category = "Mask";
    ui_tooltip = "0: Aperture Grille -- horizontal RGB stripes. Classic CRT look.\n"
                 "   Works best at larger triad widths (3+) on QD-OLED.\n"
                 "1: Diagonal Aperture Grille -- stripes offset per row.\n"
                 "   Better for QD-OLED triangular subpixels, less alignment-sensitive.\n"
                 "2: Slot Mask -- aperture grille + alternating dark rows.\n"
                 "   More shadow-mask look, good for retro content.\n"
                 "3: Trinitron -- wider green, narrower R/B (real Sony Trinitron proportions).\n"
                 "   Most accurate for Trinitron-era CRT emulation.\n"
                 "4: QD-OLED Delta -- 2x2 checkerboard matching A95L physical subpixel layout.\n"
                 "   Green at diagonal corners, Red/Blue at off-diagonal positions.\n"
                 "   Triad width scales: 2.0=native 1:1, 4.0=2x larger, 6.0=3x larger.\n"
                 "   Best at native display resolution (not DSR/downsampled).\n"
                 "5: QD-OLED Luminance Gate -- QD-OLED pattern applied proportionally to\n"
                 "   pixel luminance. Dark pixels get full phosphor assignment, bright pixels\n"
                 "   get less modulation. Highlights stay clean, shadows get texture.\n"
                 "   Closest to real CRT phosphor behaviour -- no global darkening.\n"
                 "   Use Luma Gate Threshold and Curve sliders to tune.";
    ui_items = "Aperture Grille\0Diagonal Aperture Grille\0Slot Mask\0Trinitron\0QD-OLED Delta\0QD-OLED Luma Gate\0";
> = 0;

uniform float crt_slot_mask_strength <
    ui_type = "drag"; ui_label = "Slot Mask Row Darkness";
    ui_category = "Mask";
    ui_tooltip = "Controls how dark the alternating slot rows are (Mask Type 2 only).\n"
                 "0.0 = no row darkening, 1.0 = fully dark alternate rows.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float crt_luma_gate_threshold <
    ui_type = "drag"; ui_label = "Luma Gate Threshold";
    ui_category = "Mask";
    ui_tooltip = "Luminance level above which mask starts fading out (Type 6 only).\n"
                 "0.0 = gate starts from black. 0.5 = gate starts from midtone.\n"
                 "Higher = mask visible on more of the image including brighter areas.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.2;

uniform float crt_luma_gate_curve <
    ui_type = "drag"; ui_label = "Luma Gate Curve";
    ui_category = "Mask";
    ui_tooltip = "Controls how quickly the mask fades as pixels get brighter (Type 6 only).\n"
                 "0.25 = very gradual fade. 1.0 = linear. 2.0 = sharp fade near threshold.";
    ui_min = 0.1; ui_max = 3.0; ui_step = 0.05;
> = 0.5;

uniform float crt_mask_dither <
    ui_type = "drag"; ui_label = "Mask Moiré Dither";
    ui_category = "Mask";
    ui_tooltip = "Adds a small random sub-pixel phase offset to the mask pattern\n"
                 "within each 16x16 tile, breaking the strict periodicity that\n"
                 "causes moiré interference with certain image frequencies.\n"
                 "\n"
                 "0.0 = no dither (original behaviour).\n"
                 "0.5 = subtle randomisation, moiré noticeably reduced.\n"
                 "1.0 = maximum dither -- may slightly soften mask edges at\n"
                 "      non-integer triad widths.\n"
                 "\n"
                 "Based on Haeberli and Segal (1990) display simulation work on\n"
                 "breaking periodic structure in CRT shadow mask emulation.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
> = 0.0;

uniform int crt_mask_offset_x <
    ui_type = "drag"; ui_label = "QD-OLED Mask Offset X (pixels)";
    ui_category = "Mask";
    ui_tooltip = "Horizontal pixel offset for QD-OLED Delta mask (Type 4).\n"
                 "Nudge 0 or 1 until the mask colour pattern matches your panel.\n"
                 "Test with a white screen at maximum mask strength.";
    ui_min = 0; ui_max = 1; ui_step = 1;
> = 0;

uniform int crt_mask_offset_y <
    ui_type = "drag"; ui_label = "QD-OLED Mask Offset Y (pixels)";
    ui_category = "Mask";
    ui_tooltip = "Vertical pixel offset for QD-OLED Delta mask (Type 4).\n"
                 "Nudge 0 or 1 until the mask colour pattern matches your panel.";
    ui_min = 0; ui_max = 1; ui_step = 1;
> = 0;

// ============================================================
// Uniforms -- Scanlines
// ============================================================

uniform float crt_scanline_width <
    ui_type = "drag"; ui_label = "Scanline Width (pixels)";
    ui_category = "Scanlines";
    ui_min = 1.0; ui_max = 8.0; ui_step = 0.25;
> = 4.0;

uniform float crt_scanline_strength <
    ui_type = "drag"; ui_label = "Scanline Strength";
    ui_category = "Scanlines";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float crt_r_scanline_min <
    ui_type = "drag"; ui_label = "Red Scanline Min";
    ui_category = "Scanlines";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;
uniform float crt_r_scanline_max <
    ui_type = "drag"; ui_label = "Red Scanline Max";
    ui_category = "Scanlines";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.9;
uniform float crt_r_scanline_attack <
    ui_type = "drag"; ui_label = "Red Scanline Attack";
    ui_category = "Scanlines";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float crt_g_scanline_min <
    ui_type = "drag"; ui_label = "Green Scanline Min";
    ui_category = "Scanlines";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;
uniform float crt_g_scanline_max <
    ui_type = "drag"; ui_label = "Green Scanline Max";
    ui_category = "Scanlines";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.9;
uniform float crt_g_scanline_attack <
    ui_type = "drag"; ui_label = "Green Scanline Attack";
    ui_category = "Scanlines";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float crt_b_scanline_min <
    ui_type = "drag"; ui_label = "Blue Scanline Min";
    ui_category = "Scanlines";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;
uniform float crt_b_scanline_max <
    ui_type = "drag"; ui_label = "Blue Scanline Max";
    ui_category = "Scanlines";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.9;
uniform float crt_b_scanline_attack <
    ui_type = "drag"; ui_label = "Blue Scanline Attack";
    ui_category = "Scanlines";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float crt_spot_size <
    ui_type = "drag"; ui_label = "Spot Size / Overbrightness";
    ui_category = "Scanlines";
    ui_tooltip = "On real CRTs, peak white caused the electron beam spot to\n"
                 "physically spread, brightening the scanline centre and making\n"
                 "bright pixels appear slightly larger than dark ones.\n"
                 "Luminance-dependent: only active above ~70% brightness.\n"
                 "0.0 = disabled (default). 0.1-0.3 = subtle organic bloom.\n"
                 "0.5+ = strong overbrightness on highlights.";
    ui_min = 0.0; ui_max = 0.5; ui_step = 0.01;
> = 0.0;

uniform float crt_beam_h_bloom <
    ui_type = "drag"; ui_label = "Beam Horizontal Bloom";
    ui_category = "Scanlines";
    ui_tooltip = "Simulates electron beam horizontal spreading on bright scanlines.\n"
                 "On real CRTs, very bright content causes space charge effects that\n"
                 "widen the beam horizontally as well as vertically -- saturated whites\n"
                 "appear slightly smeared sideways, softening hard horizontal edges.\n"
                 "\n"
                 "0.0 = disabled (default).\n"
                 "0.3-0.5 = subtle bloom on bright elements only.\n"
                 "1.0 = strong horizontal softening on anything above threshold.\n"
                 "\n"
                 "Only applies to pixels above ~80% luma -- darker areas unaffected.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
> = 0.0;

uniform float crt_beam_min_sigma <
    ui_type = "drag"; ui_label = "Beam Sigma Dark (pixels)";
    ui_category = "Scanlines";
    ui_tooltip = "Beam width for dark pixels in pixel units (ENABLE_BEAM_MODULATION=1).\n"
                 "Lower = tighter beam, deeper dark gaps between scanlines.\n"
                 "For visible dark gaps: keep below 0.3 * scanline_width.\n"
                 "0.5 = half a pixel wide. 1.0 = one pixel wide.";
    ui_min = 0.05; ui_max = 8.0; ui_step = 0.05;
> = 0.5;
uniform float crt_beam_max_sigma <
    ui_type = "drag"; ui_label = "Beam Sigma Bright (pixels)";
    ui_category = "Scanlines";
    ui_tooltip = "Beam width for bright pixels in pixel units (ENABLE_BEAM_MODULATION=1).\n"
                 "Higher = wider beam, brighter scanline centres bleed more.\n"
                 "Should be >= Beam Sigma Dark.";
    ui_min = 0.05; ui_max = 8.0; ui_step = 0.05;
> = 1.0;
uniform float crt_scanline_sigma <
    ui_type = "drag"; ui_label = "Beam Sigma (Fixed, BEAM_MODULATION=0)";
    ui_category = "Scanlines";
    ui_min = 0.1; ui_max = 2.0; ui_step = 0.05;
> = 0.4;

// ============================================================
// Uniforms -- Interlace
// ============================================================

#if ENABLE_INTERLACE
uniform float crt_interlace_strength <
    ui_type = "drag"; ui_label = "Interlace Strength";
    ui_category = "Interlace";
    ui_tooltip = "Simulates CRT interlaced mode by alternating which scanline\n"
                 "fields are bright and dark each frame.\n"
                 "Most visible at high framerates with BFI enabled.\n"
                 "0.0 = no effect. 1.0 = full field blanking alternation.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
> = 0.0;
#endif

// ============================================================
// Uniforms -- Gamma & Contrast
// ============================================================

uniform float crt_gamma_in <
    ui_type = "drag"; ui_label = "CRT Gamma (Input)";
    ui_category = "Gamma & Contrast";
    ui_tooltip = "Set to 1.0 inside Soop sandwich (signal is already linear).";
    ui_min = 1.0; ui_max = 3.0; ui_step = 0.01;
> = 2.2;

uniform float crt_gamma_out <
    ui_type = "drag"; ui_label = "Display Gamma (Output)";
    ui_category = "Gamma & Contrast";
    ui_tooltip = "Set to 1.0 inside Soop sandwich.";
    ui_min = 1.0; ui_max = 3.0; ui_step = 0.01;
> = 2.2;

uniform float crt_brightness <
    ui_type = "drag"; ui_label = "Brightness";
    ui_category = "Gamma & Contrast";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_contrast <
    ui_type = "drag"; ui_label = "Contrast";
    ui_category = "Gamma & Contrast";
    ui_tooltip = "Bezier contrast in Yxy space. No washout.";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_saturation <
    ui_type = "drag"; ui_label = "Saturation";
    ui_category = "Gamma & Contrast";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_colour_temp <
    ui_type = "drag"; ui_label = "Colour Temperature";
    ui_category = "Gamma & Contrast";
    ui_tooltip = "White balance adjustment relative to D65 (neutral).\n"
                 "Negative = warmer (more red/orange, less blue).\n"
                 "Positive = cooler (more blue, less red).\n"
                 "0.0 = D65 neutral (no change).\n"
                 "-0.3 to -0.5 = vintage warm CRT character.\n"
                 "Applied in linear space before BCS curves.";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

// ============================================================
// Uniforms -- Phosphor Profile
// ============================================================

#if ENABLE_PHOSPHOR
uniform int crt_phosphor_profile <
    ui_type = "combo"; ui_label = "CRT Phosphor Profile";
    ui_category = "Phosphor Profile";
    ui_tooltip = "Remaps game colours through the chosen CRT phosphor primaries to XYZ,\n"
                 "then to your display gamut. All matrices computed from documented\n"
                 "CIE xy chromaticity coordinates.\n"
                 "\n"
                 "EBU (PAL): European CRTs from 1970s. Green slightly more yellow.\n"
                 "P22: Common US consumer CRT phosphors (1970s-90s NTSC sets).\n"
                 "SMPTE-C / BVM-D / Philips: US broadcast, Sony BVM-D reference\n"
                 "  monitor, and Philips European CRTs -- all share identical\n"
                 "  chromaticities. Most PS1/PS2/N64 era games mastered on BVM-D.\n"
                 "Trinitron: Measured Sony Trinitron phosphor chromaticities.\n"
                 "NTSC 1953: Original FCC spec. Very wide gamut, Illuminant C\n"
                 "  white (~6774K). Early 1950s US TV receiver phosphors.\n"
                 "NTSC 1953 D93: Japanese CRTs (~9300K). Very cool white point.\n"
                 "  SNES/MD/Saturn as seen in Japan on consumer CRTs.\n"
                 "\n"
                 "Set ENABLE_PHOSPHOR=0 to bypass entirely.";
    ui_items = "EBU (PAL)\0"
               "P22 (US consumer)\0"
               "SMPTE-C / Sony BVM-D / Philips\0"
               "Sony Trinitron\0"
               "NTSC 1953 (Illuminant C)\0"
               "NTSC 1953 D93 (Japanese)\0";
> = 0;

uniform int crt_display_gamut <
    ui_type = "combo"; ui_label = "Display Gamut";
    ui_category = "Phosphor Profile";
    ui_tooltip = "Output colour space of your display.\n"
                 "Converts from XYZ back to your display primaries after phosphor correction.\n"
                 "0: sRGB / Rec.709 -- standard monitors\n"
                 "1: DCI-P3 Modern -- wide gamut monitors, most OLEDs\n"
                 "2: DCI-P3 -- cinema standard\n"
                 "3: Adobe RGB\n"
                 "4: Rec. 2020 -- ultra wide gamut (QD-OLED native gamut)";
    ui_items = "sRGB / Rec.709\0DCI-P3 Modern\0DCI-P3\0Adobe RGB\0Rec. 2020\0";
> = 0;

uniform float crt_phosphor_strength <
    ui_type = "drag"; ui_label = "Phosphor Correction Strength";
    ui_category = "Phosphor Profile";
    ui_tooltip = "Blends between original colours (0.0) and fully corrected phosphor colours (1.0).\n"
                 "Allows subtle correction without full commitment to one profile.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 1.0;

uniform float crt_white_point <
    ui_type = "drag"; ui_label = "White Point";
    ui_category = "Phosphor Profile";
    ui_tooltip = "Chromatic adaptation of the display white point.\n"
                 "Negative = warmer (D55 ~5500K, older consumer CRTs).\n"
                 "Zero = neutral D65 (broadcast reference, default).\n"
                 "Positive = cooler (D93 ~9300K, Japanese consumer CRTs).\n"
                 "Uses proper chromatic adaptation matrices (Guest Advanced).\n"
                 "More accurate than the Colour Temperature slider in Gamma.";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;
#endif

// ============================================================
// Uniforms -- Geometry
// ============================================================

#if ENABLE_GEOMETRY
uniform int crt_geom_mode <
    ui_type = "combo"; ui_label = "Geometry Mode";
    ui_category = "Geometry";
    ui_tooltip = "0: Flat -- no distortion (passthrough).\n"
                 "1: Spherical -- pincushion distortion on both axes.\n"
                 "   Classic consumer CRT look -- corners pull inward.\n"
                 "2: Alt Spherical -- stronger distortion at corners.\n"
                 "3: Cylindrical (Trinitron) -- horizontal curvature only.\n"
                 "   Accurate to Sony Trinitron/Mitsubishi Diamondtron tubes.\n"
                 "   Vertical edges stay straight, horizontal edges curve.";
    ui_items = "Flat\0Spherical\0Alt Spherical\0Cylindrical (Trinitron)\0";
> = 0;

uniform float crt_geom_curvature <
    ui_type = "drag"; ui_label = "Curvature Strength";
    ui_category = "Geometry";
    ui_tooltip = "How strongly the screen curves.\n"
                 "2.0 = subtle. 4.0 = moderate CRT. 6.0+ = strong vintage TV.\n"
                 "Lower values = more curvature (counterintuitively -- this is\n"
                 "the divisor in the pincushion formula, not a direct multiplier).";
    ui_min = 1.0; ui_max = 12.0; ui_step = 0.1;
> = 4.0;

uniform float crt_geom_zoom <
    ui_type = "drag"; ui_label = "Zoom";
    ui_category = "Geometry";
    ui_tooltip = "Zooms into the curved image.\n"
                 "1.0 = no zoom. Values > 1.0 zoom in (crop edges slightly).\n"
                 "Use to fill screen after curvature pulls corners in.\n"
                 "1.05-1.1 is typically enough to hide the edge clamping.";
    ui_min = 0.5; ui_max = 2.0; ui_step = 0.005;
> = 1.0;
#endif

// ============================================================
// Uniforms -- Light Warp
// ============================================================

#if ENABLE_LIGHT_WARP
uniform float crt_warp_strength <
    ui_type = "drag"; ui_label = "Warp Strength";
    ui_category = "Light Warp";
    ui_tooltip = "Lightweight barrel distortion applied to the final image.\n"
                 "Positive = barrel (CRT curve inward). Negative = pincushion.\n"
                 "0.1-0.3 = subtle CRT curve. 0.5+ = strong distortion.\n"
                 "Can be combined with ENABLE_GEOMETRY for stacked warp effects.";
    ui_min = -0.5; ui_max = 0.5; ui_step = 0.01;
> = 0.0;

uniform float3 crt_warp_border_colour <
    ui_type = "color"; ui_label = "Warp Border Colour";
    ui_category = "Light Warp";
    ui_tooltip = "Colour outside the warped screen boundary. Black = authentic CRT.";
> = float3(0.0, 0.0, 0.0);

uniform float crt_pin_phase <
    ui_type = "drag"; ui_label = "Pin Phase";
    ui_category = "Light Warp";
    ui_tooltip = "Horizontal scan linearity error -- horizontal position varies with\n"
                 "vertical scan position. Based on Sony Megatron.\n"
                 "Models CRT deflection yoke geometry where horizontal linearity\n"
                 "changes with vertical deflection angle.\n"
                 "Positive = pincushion. Negative = barrel.\n"
                 "0.0 = disabled (default). 0.02-0.05 = subtle. 0.1+ = strong.";
    ui_min = -0.2; ui_max = 0.2; ui_step = 0.005;
> = 0.0;

uniform float crt_pin_amp <
    ui_type = "drag"; ui_label = "Pin Amp";
    ui_category = "Light Warp";
    ui_tooltip = "Vertical scan linearity error -- vertical position of each column\n"
                 "varies with its horizontal position. Vertical complement to Pin Phase.\n"
                 "Combined with Pin Phase gives full pincushion/barrel raster geometry.\n"
                 "Positive = pincushion. Negative = barrel.\n"
                 "0.0 = disabled (default). 0.02-0.05 = subtle. 0.1+ = strong.";
    ui_min = -0.2; ui_max = 0.2; ui_step = 0.005;
> = 0.0;
#endif

// ============================================================
// Uniforms -- Brightness & Glow
// ============================================================

uniform float crt_bb_dark <
    ui_type = "drag"; ui_label = "Bright Boost (Dark Areas)";
    ui_category = "Brightness & Glow";
    ui_tooltip = ">1.0 lifts scanline gaps to glow. <1.0 crushes them deeper.";
    ui_min = 0.1; ui_max = 3.0; ui_step = 0.05;
> = 1.0;

uniform float crt_bb_bright <
    ui_type = "drag"; ui_label = "Bright Boost (Bright Areas)";
    ui_category = "Brightness & Glow";
    ui_tooltip = "<1.0 restrains highlights (Guest brightboost2 style).";
    ui_min = 0.1; ui_max = 3.0; ui_step = 0.05;
> = 1.0;

uniform int crt_bb_mode <
    ui_type = "combo";
    ui_label = "Bright Boost Reference";
    ui_category = "Brightness & Glow";
    ui_tooltip = "Peak Channel: colour-agnostic, correct for CRT phosphor physics.\n"
                 "Treats R, G, B equally regardless of luminance weight.\n"
                 "Best for high-saturation single-channel content (e.g. blue-heavy scenes).\n"
                 "\n"
                 "Luma (Rec.709): perceptually weighted, may under-represent blue.\n"
                 "Can cause colour shifts in blue-dominant scenes inside Soop/Luma sandwich.\n"
                 "\n"
                 "Per Channel: each channel boosted independently by its own value.\n"
                 "No peak-channel bias -- eliminates warm/cool hue shift at high boost values.\n"
                 "May slightly change saturation since channels scale differently.";
    ui_items = "Peak Channel\0Luma (Rec.709)\0Per Channel\0";
> = 0;

uniform float crt_glow_strength <
    ui_type = "drag"; ui_label = "Glow Strength";
    ui_category = "Brightness & Glow";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_glow_h_radius <
    ui_type = "drag"; ui_label = "Glow Horizontal Radius";
    ui_category = "Brightness & Glow";
    ui_min = 1.0; ui_max = 64.0; ui_step = 1.0;
> = 12.0;

uniform float crt_glow_v_radius <
    ui_type = "drag"; ui_label = "Glow Vertical Radius";
    ui_category = "Brightness & Glow";
    ui_min = 1.0; ui_max = 16.0; ui_step = 0.5;
> = 3.0;

uniform float crt_glow_sigma <
    ui_type = "drag"; ui_label = "Glow Sigma";
    ui_category = "Brightness & Glow";
    ui_min = 0.1; ui_max = 4.0; ui_step = 0.05;
> = 1.2;

uniform float crt_glow_wide_strength <
    ui_type = "drag"; ui_label = "Wide Glow Strength";
    ui_category = "Brightness & Glow";
    ui_tooltip = "Dual-scale bloom: a second, much wider glow pass that creates\n"
                 "a broad soft halo over large bright areas (sky, windows, surfaces).\n"
                 "Complements the tight glow which handles small bright elements.\n"
                 "\n"
                 "0.0 = disabled (default). 0.1-0.3 = subtle area bloom.\n"
                 "0.5+ = strong area fill, good for bright outdoor scenes.\n"
                 "\n"
                 "Runs at quarter resolution -- very cheap additional pass.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_glow_wide_radius <
    ui_type = "drag"; ui_label = "Wide Glow Radius";
    ui_category = "Brightness & Glow";
    ui_tooltip = "Radius of the wide bloom pass in pixels at half-resolution.\n"
                 "Higher = larger soft area halo. Keep well above tight glow radius.";
    ui_min = 1.0; ui_max = 16.0; ui_step = 0.5;
> = 8.0;

uniform float crt_glow_wide_threshold <
    ui_type = "drag"; ui_label = "Wide Glow Threshold";
    ui_category = "Brightness & Glow";
    ui_tooltip = "Luminance threshold for the wide bloom pass.\n"
                 "Typically set lower than tight glow threshold so the wide pass\n"
                 "captures more of the scene rather than just peak highlights.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_glow_spectral <
    ui_type = "drag"; ui_label = "Spectral Bloom";
    ui_category = "Brightness & Glow";
    ui_tooltip = "Physically based chromatic bloom: blue light diffracts more\n"
                 "than red through a lens, so the blue channel blooms wider.\n"
                 "\n"
                 "0.0 = uniform bloom, all channels same width (default).\n"
                 "0.5 = subtle coloured fringe on bright elements.\n"
                 "1.0 = full separation: R=0.75x, G=1.0x, B=1.35x sigma.\n"
                 "\n"
                 "Based on wavelength-dependent diffraction -- shorter wavelengths\n"
                 "spread more than longer ones through optical glass.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
> = 0.0;

uniform float crt_glow_threshold <
    ui_type = "drag"; ui_label = "Glow Threshold";
    ui_category = "Brightness & Glow";
    ui_tooltip = "Luminance level below which glow is suppressed.\n"
                 "0.0 = all pixels contribute to glow.\n"
                 "0.3+ = only bright elements bloom.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_glow_knee <
    ui_type = "drag"; ui_label = "Glow Knee";
    ui_category = "Brightness & Glow";
    ui_tooltip = "Controls how selectively glow is applied across luminance levels.\n"
                 "\n"
                 "0.0 = original behaviour: hard threshold, all pixels above it\n"
                 "      contribute equally (weighted by luma).\n"
                 "\n"
                 "Above 0: dark pixels contribute progressively less to glow,\n"
                 "bright pixels contribute fully. Creates better contrast between\n"
                 "lit and unlit areas -- glow feels more localised to bright\n"
                 "elements rather than bleeding into dark regions of the scene.\n"
                 "\n"
                 "Works even at Threshold=0: the knee creates a natural luminance\n"
                 "ramp from 0 to the knee width, suppressing dark pixel glow\n"
                 "contribution without cutting it off entirely.\n"
                 "\n"
                 "Suggested starting point: 0.1-0.3. Higher values (0.4-0.5)\n"
                 "are more aggressive -- useful for scenes with strong contrast\n"
                 "between bright elements and dark backgrounds. The ideal value\n"
                 "varies by game brightness distribution.";
    ui_min = 0.0; ui_max = 0.5; ui_step = 0.01;
> = 0.0;

uniform float crt_glow_h_mix <
    ui_type = "drag"; ui_label = "Horizontal vs Vertical Glow Mix";
    ui_category = "Brightness & Glow";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
> = 0.7;

uniform float crt_glow_balance <
    ui_type = "drag"; ui_label = "Glow Colour Balance";
    ui_category = "Brightness & Glow";
    ui_tooltip = "0.0 = neutral white glow, 1.0 = raw colour.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
> = 0.0;

// ============================================================
// Uniforms -- Halation
// ============================================================

#if ENABLE_HALATION
uniform float crt_halation_strength <
    ui_type = "drag"; ui_label = "Halation Strength";
    ui_category = "Halation";
    ui_tooltip = "Strength of the phosphor glass scatter bloom.\nOnly affects bright elements against dark backgrounds -- not a global haze.\nSet ENABLE_HALATION=0 in preprocessor to remove the pass entirely.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_halation_threshold <
    ui_type = "drag"; ui_label = "Halation Threshold";
    ui_category = "Halation";
    ui_tooltip = "Only pixels brighter than this feed into the halation bloom.\nHigher = only extreme highlights scatter.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.6;

uniform float crt_halation_radius <
    ui_type = "drag"; ui_label = "Halation Radius";
    ui_category = "Halation";
    ui_tooltip = "Spread of the glass scatter in pixels (at quarter resolution).\nHigher = wider bloom around bright elements.";
    ui_min = 1.0; ui_max = 16.0; ui_step = 0.5;
> = 6.0;

uniform float crt_halation_sigma <
    ui_type = "drag"; ui_label = "Halation Sigma";
    ui_category = "Halation";
    ui_min = 0.1; ui_max = 8.0; ui_step = 0.1;
> = 3.0;

uniform float crt_halation_anisotropy <
    ui_type = "drag"; ui_label = "Halation Anisotropy";
    ui_category = "Halation";
    ui_tooltip = "Controls the horizontal vs vertical spread ratio of halation.\n"
                 "1.0 (default) = isotropic -- same spread in both directions.\n"
                 "2.0 = horizontal spread is 2x wider than vertical (realistic CRT:\n"
                 "      shadow mask stripes run vertically, so light bleeds more\n"
                 "      horizontally along the stripe direction).\n"
                 "0.5 = vertical spread wider than horizontal.\n"
                 "Does not affect your existing radius/sigma/strength settings.";
    ui_min = 0.25; ui_max = 4.0; ui_step = 0.05;
> = 1.0;

uniform float crt_halation_saturation <
    ui_type = "drag"; ui_label = "Halation Desaturation";
    ui_category = "Halation";
    ui_tooltip = "How much the scattered light desaturates toward warm white.\n0.0 = full colour scatter, 1.0 = fully desaturated (warm white glow).\nResolution: set HALATION_RESOLUTION=4 (quarter), 2 (half), 1 (full) in preprocessor.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.6;

uniform float crt_halation_warmth <
    ui_type = "drag"; ui_label = "Halation Warmth";
    ui_category = "Halation";
    ui_tooltip = "Colour temperature of the halation glow.\n"
                 "0.0 = pure white scatter (neutral).\n"
                 "1.0 = warm orange-red tint (realistic phosphor backscatter).\n"
                 "Real CRT halation is slightly warm due to phosphor spectral\n"
                 "emission bleeding through the glass.\n"
                 "Works alongside Desaturation: desaturation removes colour,\n"
                 "warmth tints what remains.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;


#endif // ENABLE_HALATION

// ============================================================
#if ENABLE_CA
// Uniforms -- Chromatic Aberration
// ============================================================

uniform float crt_ca_strength <
    ui_type = "drag"; ui_label = "CA Strength";
    ui_category = "Chromatic Aberration";
    ui_tooltip = "Radial chromatic aberration strength.\n"
                 "Simulates glass lens dispersion: short wavelengths (blue) refract\n"
                 "more than long wavelengths (red), causing colour fringing that\n"
                 "increases with distance from screen centre.\n"
                 "Zero at centre, maximum at corners.\n"
                 "0.0 = disabled. 0.002-0.005 = subtle. 0.01+ = strong.\n"
                 "Integrates with geometry curvature -- CA follows the warp.";
    ui_min = 0.0; ui_max = 0.02; ui_step = 0.0005;
> = 0.0;

uniform float crt_ca_falloff <
    ui_type = "drag"; ui_label = "CA Falloff";
    ui_category = "Chromatic Aberration";
    ui_tooltip = "Controls how quickly CA builds up from centre to edge.\n"
                 "1.0 = linear -- CA scales linearly with distance from centre.\n"
                 "2.0 = quadratic -- CA is subtle near centre, strong at corners.\n"
                 "     More physically accurate for simple lens models.\n"
                 "3.0+ = cubic -- very concentrated at corners only.";
    ui_min = 1.0; ui_max = 4.0; ui_step = 0.1;
> = 2.0;
#endif // ENABLE_CA

// ============================================================
#if ENABLE_CONVERGENCE
// Uniforms -- Convergence
// ============================================================

uniform float crt_convergence_r <
    ui_type = "drag"; ui_label = "Red Vertical Convergence";
    ui_category = "Convergence";
    ui_tooltip = "Vertical offset of the red channel in pixels.\nNegative = shift up, positive = shift down.\nPVM-2730 uses -0.14. Safe with ENABLE_MASK=0.";
    ui_min = -4.0; ui_max = 4.0; ui_step = 0.01;
> = 0.0;

uniform float crt_convergence_g <
    ui_type = "drag"; ui_label = "Green Vertical Convergence";
    ui_category = "Convergence";
    ui_min = -4.0; ui_max = 4.0; ui_step = 0.01;
> = 0.0;

uniform float crt_convergence_b <
    ui_type = "drag"; ui_label = "Blue Vertical Convergence";
    ui_category = "Convergence";
    ui_min = -4.0; ui_max = 4.0; ui_step = 0.01;
> = 0.0;

uniform float crt_convergence_h_r <
    ui_type = "drag"; ui_label = "Red Horizontal Convergence";
    ui_category = "Convergence";
    ui_tooltip = "Horizontal offset of the red channel in pixels.\n"
                 "Negative = left, positive = right.\n"
                 "Complements vertical convergence and radial CA.";
    ui_min = -3.0; ui_max = 3.0; ui_step = 0.1;
> = 0.0;

uniform float crt_convergence_h_b <
    ui_type = "drag"; ui_label = "Blue Horizontal Convergence";
    ui_category = "Convergence";
    ui_tooltip = "Horizontal offset of the blue channel in pixels.\n"
                 "Negative = left, positive = right.";
    ui_min = -3.0; ui_max = 3.0; ui_step = 0.1;
> = 0.0;

uniform float crt_convergence_v_spread <
    ui_type = "drag"; ui_label = "Vertical Beam Spread";
    ui_category = "Convergence";
    ui_tooltip = "Slightly blurs each channel vertically by a different amount,\n"
                 "simulating the physical offset of the three electron guns in a\n"
                 "colour CRT. Adds organic softness independent of convergence.\n"
                 "0.0 = disabled (default). 0.3-0.7 = subtle per-channel spread.";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.05;
> = 0.0;

uniform float crt_convergence_radial <
    ui_type = "drag"; ui_label = "Radial Misconvergence";
    ui_category = "Convergence";
    ui_tooltip = "Physically based pincushion misconvergence model.\n"
                 "Real CRT electron guns have convergence errors that grow\n"
                 "toward the screen edges: delta_y = k * x^2\n"
                 "where x is normalised horizontal distance from centre.\n"
                 "\n"
                 "Added ON TOP of the uniform convergence offsets above.\n"
                 "At screen centre: no additional error. At edges: maximum.\n"
                 "Red diverges up, Blue diverges down at the edges.\n"
                 "\n"
                 "0.0 = disabled (default). 0.5-1.0 = subtle authentic\n"
                 "misconvergence. 2.0+ = strong edge colour fringing.";
    ui_min = 0.0; ui_max = 4.0; ui_step = 0.1;
> = 0.0;
#endif // ENABLE_CONVERGENCE

// ============================================================
#if ENABLE_VIGNETTE
// Uniforms -- Vignette
// ============================================================

uniform int crt_vignette_shape <
    ui_type = "combo"; ui_label = "Vignette Shape";
    ui_category = "Vignette";
    ui_items = "Rectangular (CRT-authentic)\0"
               "Circular / Elliptical (original)\0";
    ui_tooltip = "Rectangular: multiplies independent H and V falloffs.\n"
                 "Corners are naturally darker than edges -- most authentic\n"
                 "to real CRT electron beam intensity falloff.\n"
                 "\n"
                 "Circular: original dot(uv,uv) radial falloff.\n"
                 "Produces an oval on 16:9 screens (touches top/bottom\n"
                 "before sides). Smooth gradient, single power control.\n"
                 "V Power has no effect in this mode.";
> = 1;

uniform float crt_vignette_strength <
    ui_type = "drag"; ui_label = "Vignette Strength";
    ui_category = "Vignette";
    ui_tooltip = "Luminance falloff toward screen edges.\n"
                 "Rectangular CRT-authentic shape: H and V falloffs multiply,\n"
                 "naturally producing darker corners than edges.\n"
                 "0.0 = disabled, 0.15 = subtle, 0.4 = strong.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_vignette_power <
    ui_type = "drag"; ui_label = "Vignette H Power";
    ui_category = "Vignette";
    ui_tooltip = "Horizontal falloff curve. Higher = faster dropoff toward left/right edges.\n"
                 "Controls how quickly brightness drops as you move toward the sides.\n"
                 "Also controls overall power in Circular mode.\n"
                 "Rectangular: keep between 1.0-2.5 to avoid a sliver effect.";
    ui_min = 0.5; ui_max = 8.0; ui_step = 0.1;
> = 1.5;

uniform float crt_vignette_v_power <
    ui_type = "drag"; ui_label = "Vignette V Power";
    ui_category = "Vignette";
    ui_tooltip = "Vertical falloff curve. Higher = faster dropoff toward top/bottom edges.\n"
                 "Typically set lower than H power on wide CRTs (less vertical curvature).\n"
                 "Setting equal to H power gives symmetric falloff.\n"
                 "No effect in Circular mode.\n"
                 "Rectangular: keep between 1.0-2.5 to avoid a sliver effect.";
    ui_min = 0.5; ui_max = 8.0; ui_step = 0.1;
> = 1.5;

uniform float crt_vignette_hdr_threshold <
    ui_type = "drag"; ui_label = "Highlight Protection Threshold";
    ui_category = "Vignette";
    ui_tooltip = "Luminance above which highlights are progressively protected.\n"
                 "Pixels brighter than this start receiving less vignette darkening.\n"
                 "0.5 = protect upper midtones and highlights.\n"
                 "0.7 = only protect bright highlights.\n"
                 "1.0 = no protection (vignette affects everything equally).";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float crt_vignette_hdr_strength <
    ui_type = "drag"; ui_label = "Highlight Protection Strength";
    ui_category = "Vignette";
    ui_tooltip = "How strongly highlights above the threshold are protected.\n"
                 "0.0 = no protection (original behaviour).\n"
                 "0.5 = partial protection -- highlights still darkened but less so.\n"
                 "1.0 = full protection -- highlights above threshold fully isolated.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;
#endif // ENABLE_VIGNETTE

// ============================================================
// Uniforms -- Corner Rounding
// ============================================================

#if ENABLE_CORNER_ROUND
uniform float crt_corner_size <
    ui_type = "drag"; ui_label = "Corner Size";
    ui_category = "Corner Rounding";
    ui_tooltip = "Radius of the rounded screen corners.\n"
                 "0.0 = square corners. 0.05-0.10 = subtle rounding.\n"
                 "0.15-0.25 = strong rounded corners like a consumer TV.";
    ui_min = 0.0; ui_max = 0.35; ui_step = 0.01;
> = 0.0;

uniform float crt_corner_border <
    ui_type = "drag"; ui_label = "Border Size";
    ui_category = "Corner Rounding";
    ui_tooltip = "Adds a darkened shadow border around all four edges of the screen,\n"
                 "simulating the bezel shadow cast by the CRT housing.\n"
                 "0.0 = no border. 0.5-1.0 = subtle edge shadow. 2.0 = strong bezel.";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 0.0;

uniform float crt_corner_intensity <
    ui_type = "drag"; ui_label = "Border Intensity";
    ui_category = "Corner Rounding";
    ui_tooltip = "Power curve applied to the corner/border mask.\n"
                 "Higher = sharper, harder edge with more contrast.\n"
                 "Lower = softer, more gradual transition.\n"
                 "0.25 = very soft. 1.0 = linear. 2.0 = sharp (default).";
    ui_min = 0.25; ui_max = 4.0; ui_step = 0.05;
> = 2.0;

uniform float crt_corner_shadow <
    ui_type = "drag"; ui_label = "Corner Shadow";
    ui_category = "Corner Rounding";
    ui_tooltip = "Darkening at the extreme corners of the screen, simulating\n"
                 "the shadow cast by the CRT bezel pressing against the tube.\n"
                 "Independent of corner rounding -- works at any geometry setting.\n"
                 "0.0 = disabled. 0.2-0.5 = subtle darkening. 1.0 = strong shadow.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;
#endif

// ============================================================
// Uniforms -- Edge Blur
// ============================================================

#if ENABLE_EDGE_BLUR
uniform float crt_edge_blur_strength <
    ui_type = "drag"; ui_label = "Edge Blur Strength";
    ui_category = "Edge Blur";
    ui_tooltip = "Simulates CRT glass optical defocus toward screen edges.\n"
                 "Centre stays sharp, edges soften gradually.\n"
                 "Set ENABLE_EDGE_BLUR=0 in preprocessor to remove entirely.\n"
                 "0.0 = disabled at runtime.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_edge_blur_falloff <
    ui_type = "drag"; ui_label = "Edge Blur Falloff";
    ui_category = "Edge Blur";
    ui_tooltip = "How far from centre the blur begins.\n"
                 "Higher = blur starts closer to edges (tighter safe zone).\n"
                 "Lower = blur creeps toward centre.";
    ui_min = 0.5; ui_max = 4.0; ui_step = 0.1;
> = 2.0;

uniform float crt_edge_blur_radius <
    ui_type = "drag"; ui_label = "Edge Blur Max Radius (pixels)";
    ui_category = "Edge Blur";
    ui_tooltip = "Maximum disc sample radius at screen corners in pixels.\n"
                 "Keep low (2-6) for subtle optical softening.";
    ui_min = 0.5; ui_max = 16.0; ui_step = 0.25;
> = 3.0;

#endif // ENABLE_EDGE_BLUR

// ============================================================
// Uniforms -- Screen Reflection
// ============================================================

#if ENABLE_SCREEN_REFLECT
uniform float crt_reflect_strength <
    ui_type = "drag"; ui_label = "Reflection Strength";
    ui_category = "Screen Reflection";
    ui_tooltip = "Faint blurred self-reflection simulating light bouncing between\n"
                 "the thick CRT glass and the phosphor tube.\n"
                 "A blurred copy of the image composited additively at screen edges,\n"
                 "fading toward the centre. Most visible on dark backgrounds with\n"
                 "bright content near the edges. Based on Mega Bezel concept (GPLv3).\n"
                 "0.0 = disabled. 0.02-0.05 = subtle. 0.1+ = visible.";
    ui_min = 0.0; ui_max = 0.3; ui_step = 0.005;
> = 0.0;

uniform float crt_reflect_gamma <
    ui_type = "drag"; ui_label = "Reflection Gamma";
    ui_category = "Screen Reflection";
    ui_tooltip = "Gamma applied to the reflection before compositing.\n"
                 "Higher = reflection concentrated on brighter content.\n"
                 "Lower = more uniform reflection across all tones.";
    ui_min = 0.5; ui_max = 4.0; ui_step = 0.05;
> = 2.0;

uniform float crt_reflect_fade <
    ui_type = "drag"; ui_label = "Edge Fade";
    ui_category = "Screen Reflection";
    ui_tooltip = "How quickly the reflection fades toward the screen centre.\n"
                 "Higher = reflection concentrated at extreme edges.\n"
                 "Lower = reflection extends further inward.";
    ui_min = 0.5; ui_max = 8.0; ui_step = 0.1;
> = 3.0;
#endif // ENABLE_SCREEN_REFLECT

// ============================================================
// Uniforms -- Tube Diffuse
// ============================================================

#if ENABLE_TUBE_DIFFUSE
uniform float crt_tube_diffuse_strength <
    ui_type = "drag"; ui_label = "Tube Diffuse Strength";
    ui_category = "Tube Diffuse";
    ui_tooltip = "Ambient glow from phosphors scattering through the CRT glass.\n"
                 "A heavily blurred copy of the final image composited additively.\n"
                 "Creates faint warmth proportional to scene brightness.\n"
                 "Different from halation (which halos bright elements).\n"
                 "Based on Mega Bezel fullscreen glow concept (GPLv3).\n"
                 "0.0 = disabled. 0.02-0.06 = subtle ambient warmth. 0.15+ = strong.";
    ui_min = 0.0; ui_max = 0.3; ui_step = 0.005;
> = 0.0;

uniform float crt_tube_diffuse_gamma <
    ui_type = "drag"; ui_label = "Tube Diffuse Gamma";
    ui_category = "Tube Diffuse";
    ui_tooltip = "Gamma applied to the diffuse glow before compositing.\n"
                 "Higher = effect concentrated on brighter content.\n"
                 "Lower = more uniform ambient lift across all tones.";
    ui_min = 0.5; ui_max = 4.0; ui_step = 0.05;
> = 2.0;
#endif // ENABLE_TUBE_DIFFUSE

// ============================================================
// Uniforms -- Edge Feedback
// ============================================================

#if ENABLE_EDGE_FEEDBACK
uniform float crt_edge_feedback_luma <
    ui_type = "drag"; ui_label = "Edge Feedback Strength";
    ui_category = "Edge Feedback";
    ui_tooltip = "Amplifies CRT edge and peripheral effects by comparing the current\n"
                 "pixel against its neighbours from the previous rendered frame.\n"
                 "The difference captures accumulated CRT processing (mask transitions,\n"
                 "scanline gaps, vignette gradient) and feeds it back as edge enhancement.\n"
                 "Effect is strongest at screen edges and geometry-warped areas.\n"
                 "Most effective with ENABLE_GEOMETRY=1.\n"
                 "0.0 = disabled. 0.1-0.3 = subtle. 0.5+ = strong.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_edge_feedback_chroma <
    ui_type = "drag"; ui_label = "Chroma Diffusion";
    ui_category = "Edge Feedback";
    ui_tooltip = "Softens colour channels horizontally using the previous frame as\n"
                 "reference. Creates a subtle chroma diffusion on moving content.\n"
                 "Most effective with ENABLE_GEOMETRY=1.\n"
                 "0.0 = disabled. 0.3-0.6 = subtle. 1.0 = strong diffusion.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;
#endif // ENABLE_EDGE_FEEDBACK

// ============================================================
#if ENABLE_GRAIN
// Uniforms -- Film Grain
// ============================================================

uniform float crt_grain_intensity <
    ui_type = "drag"; ui_label = "Grain Intensity";
    ui_category = "Film Grain";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.005;
> = 0.0;

uniform bool crt_grain_colour <
    ui_label = "Colour Grain";
    ui_category = "Film Grain";
> = false;

uniform bool crt_grain_animate <
    ui_label = "Animate Grain";
    ui_category = "Film Grain";
> = true;


uniform float crt_grain_shadows <
    ui_type = "drag"; ui_label = "Shadow Grain Amount";
    ui_category = "Film Grain";
    ui_tooltip = "0.0 = no grain in blacks, prevents black lift.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_grain_size <
    ui_type = "drag"; ui_label = "Grain Size";
    ui_category = "Film Grain";
    ui_tooltip = "Controls grain clump size via diffusion pass (matches Marty METEOR).\n"
                 "0.0 = finest single-pixel grain.\n"
                 "1.0 = largest, most organic clumping.\n"
                 "Marty default is ~0.3.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.2;

#endif // ENABLE_GRAIN

// ============================================================
// Uniforms -- Noise Floor
// ============================================================

#if ENABLE_NOISE_FLOOR
uniform float crt_noise_floor <
    ui_type = "drag"; ui_label = "Noise Floor";
    ui_category = "Noise Floor";
    ui_tooltip = "Faint fixed-pattern thermal noise on dark areas.\n"
                 "Simulates CRT electronics thermal noise -- different from film\n"
                 "grain which is signal-dependent. Noise floor is constant,\n"
                 "additive, and most visible on near-black areas.\n"
                 "0.0 = disabled (default). 0.005-0.02 = authentic subtle noise.";
    ui_min = 0.0; ui_max = 0.5; ui_step = 0.005;
> = 0.0;

uniform float crt_noise_floor_scale <
    ui_type = "drag"; ui_label = "Noise Floor Scale";
    ui_category = "Noise Floor";
    ui_tooltip = "Spatial scale of the noise pattern. 1.0 = per-pixel noise.\n"
                 "2.0-4.0 = coarser pattern, more visible structure.";
    ui_min = 1.0; ui_max = 8.0; ui_step = 0.5;
> = 1.0;
#endif // ENABLE_NOISE_FLOOR

// ============================================================
// Uniforms -- Phosphor Decay
// Two methods selectable at runtime:
//   0 = Fibonacci (CRT Dusha-style, uniform darkening)
//   1 = Variable MPRT (Blur Busters, brightness-preserving)
// Set ENABLE_DECAY=1 to enable. Best at 120fps+.
// ============================================================

#if ENABLE_DECAY

uniform float crt_phosphor_trail_r <
    ui_type = "drag"; ui_label = "Phosphor Trail Red Tint";
    ui_category = "Phosphor Decay";
    ui_tooltip = "Colour tint on the red channel of the persistence trail.\n"
                 "Real phosphors shift hue as they decay -- P22 red drifts\n"
                 "slightly orange. 0.0 = no tint (default).";
    ui_min = -0.5; ui_max = 0.5; ui_step = 0.01;
> = 0.0;

uniform float crt_phosphor_trail_g <
    ui_type = "drag"; ui_label = "Phosphor Trail Green Tint";
    ui_category = "Phosphor Decay";
    ui_tooltip = "Colour tint on the green channel of the persistence trail.\n"
                 "P22 green shifts slightly yellow-green as it decays.\n"
                 "0.0 = no tint (default).";
    ui_min = -0.5; ui_max = 0.5; ui_step = 0.01;
> = 0.0;

uniform float crt_phosphor_trail_b <
    ui_type = "drag"; ui_label = "Phosphor Trail Blue Tint";
    ui_category = "Phosphor Decay";
    ui_tooltip = "Colour tint on the blue channel of the persistence trail.\n"
                 "Blue phosphors shift toward cyan as they cool.\n"
                 "0.0 = no tint (default).";
    ui_min = -0.5; ui_max = 0.5; ui_step = 0.01;
> = 0.0;

// -- Shared --------------------------------------------------
uniform int crt_decay_method <
    ui_type = "combo";
    ui_label = "Decay Method";
    ui_category = "Phosphor Decay";
    ui_items = "Fibonacci (uniform darkening)\0"
               "Variable MPRT (Blur Busters - SDR only)\0"
               "BFI - Black Frame Insertion\0";
    ui_tooltip = "Fibonacci: uniform per-frame darkening. Works at any fps, any pipeline.\n"
                 "No history frames, no pipeline dependency.\n"
                 "\n"
                 "Variable MPRT (SDR only): Blur Busters brightness-budget algorithm.\n"
                 "Dark pixels decay fast, bright pixels preserve energy across frames.\n"
                 "PIPELINE 0 only -- uses sRGB transfer function internally.\n"
                 "On PIPELINE 1/2 highlights will be remapped incorrectly (use BFI instead).\n"
                 "Enable Raster Sweep for 240Hz+ spatial variation (experimental).\n"
                 "\n"
                 "BFI: Hard black frame insertion, correct for any pipeline.\n"
                 "PIPELINE 0: gain applied in sRGB->linear->sRGB space.\n"
                 "PIPELINE 1/2: gain applied via InvReinhard->scale->Reinhard.\n"
                 "No history frames. Recommended for PIPELINE 1/2.";
> = 0;

uniform int crt_decay_frames <
    ui_type = "drag"; ui_label = "Frames per Decay Cycle";
    ui_category = "Phosphor Decay";
    ui_tooltip = "Number of frames in one full decay cycle (all methods).\n"
                 "At 120fps: 2 = 60 bright/sec (recommended).\n"
                 "Higher = more motion clarity, less perceived brightness.";
    ui_min = 2; ui_max = 8; ui_step = 1;
> = 2;

// -- Phosphor Decay - Fibonacci ------------------------------
uniform int crt_decay_stages <
    ui_type = "drag"; ui_label = "Decay Stages";
    ui_category = "Phosphor Decay - Fibonacci";
    ui_tooltip = "Number of Fibonacci-weighted exponential decay stages.\n"
                 "More stages = richer decay curve, darker later frames.\n"
                 "2-3 = subtle, 5-7 = strong phosphor trail effect.";
    ui_min = 1; ui_max = 8; ui_step = 1;
> = 5;

uniform float crt_decay_speed <
    ui_type = "drag"; ui_label = "Global Decay Speed";
    ui_category = "Phosphor Decay - Fibonacci";
    ui_tooltip = "How quickly phosphor brightness fades across the cycle.\n"
                 "Higher = darker decay frames, more motion clarity.";
    ui_min = 0.1; ui_max = 20.0; ui_step = 0.1;
> = 5.0;

uniform float crt_decay_r <
    ui_type = "drag"; ui_label = "Red Phosphor Decay";
    ui_category = "Phosphor Decay - Fibonacci";
    ui_tooltip = "Relative decay speed for red channel.\n"
                 "Lower = longer red trail (P22 red decays slowest).";
    ui_min = 0.1; ui_max = 3.0; ui_step = 0.05;
> = 0.5;

uniform float crt_decay_g <
    ui_type = "drag"; ui_label = "Green Phosphor Decay";
    ui_category = "Phosphor Decay - Fibonacci";
    ui_tooltip = "Relative decay speed for green channel.";
    ui_min = 0.1; ui_max = 3.0; ui_step = 0.05;
> = 0.6;

uniform float crt_decay_b <
    ui_type = "drag"; ui_label = "Blue Phosphor Decay";
    ui_category = "Phosphor Decay - Fibonacci";
    ui_tooltip = "Relative decay speed for blue channel. Blue decays fastest.";
    ui_min = 0.1; ui_max = 3.0; ui_step = 0.05;
> = 0.8;

uniform float crt_decay_floor <
    ui_type = "drag"; ui_label = "Decay Floor";
    ui_category = "Phosphor Decay - Fibonacci";
    ui_tooltip = "Minimum brightness decay frames can reach.\n"
                 "0.0 = fully dark. 0.5 = stays 50% bright. 1.0 = no darkening.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float crt_decay_sine_blend <
    ui_type = "drag"; ui_label = "Sine Smoothing";
    ui_category = "Phosphor Decay - Fibonacci";
    ui_tooltip = "Blends decay curve toward smooth cosine wave.\n"
                 "0.0 = hard step. 1.0 = full sine. 0.5-0.8 recommended.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.7;

uniform float crt_decay_luma_protect <
    ui_type = "drag"; ui_label = "Highlight Protection";
    ui_category = "Phosphor Decay - Fibonacci";
    ui_tooltip = "Reduces decay on bright pixels.\n"
                 "0.0 = all pixels equal. 1.0 = highlights barely decay.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.20;

// -- Phosphor Decay - BFI / Variable MPRT --------------------
// Gain: shared by BFI (method 2) and Variable MPRT (method 1).
// Hidden when Fibonacci is selected.
uniform float crt_decay_gain <
    ui_type = "drag"; ui_label = "Gain vs Blur";
    ui_category = "Phosphor Decay - BFI / Variable MPRT";
    ui_tooltip = "Lit frame brightness multiplier.\n"
                 "litGain = frames x gain. With frames=2:\n"
                 "  0.5 (default): litGain=1.0, lit frame = signal unchanged.\n"
                 "    No clipping on any content. Sky/bloom look correct.\n"
                 "  > 0.5: lit frame is boosted to partially recover average\n"
                 "    brightness, but bright content clips to grey/white.\n"
                 "If you see flicker or highlights greying out, reduce below 0.5.";
    ui_min = 0.3; ui_max = 1.0; ui_step = 0.01;
> = 0.5;

uniform float crt_decay_dark_floor <
    ui_type = "drag"; ui_label = "VRR Dark Frame Floor";
    ui_category = "Phosphor Decay - BFI / Variable MPRT (Experimental)";
    ui_tooltip = "Minimum brightness of dark frames. 0.0 = pure black (default).\n"
                 "\n"
                 "Under VRR, frame display times are irregular -- a lit frame\n"
                 "may show for 6ms and the next dark frame for 14ms, or vice\n"
                 "versa. The eye integrates varying lit/dark ratios each cycle,\n"
                 "producing irregular brightness fluctuation (VRR flicker).\n"
                 "\n"
                 "Raising this floor reduces the brightness swing between lit\n"
                 "and dark frames, directly reducing flicker amplitude at the\n"
                 "cost of some motion clarity (dark frames are no longer black).\n"
                 "\n"
                 "0.00 = maximum clarity, maximum VRR flicker (locked Hz only).\n"
                 "0.10 = good balance, flicker mostly eliminated on VRR displays.\n"
                 "0.20 = very stable, noticeable clarity reduction.\n"
                 "Start at 0.0 and raise until VRR flicker becomes acceptable.";
    ui_min = 0.0; ui_max = 0.5; ui_step = 0.01;
> = 0.0;

uniform bool crt_decay_dark_blend <
    ui_label = "VRR Dark Frame Blend";
    ui_category = "Phosphor Decay - BFI / Variable MPRT (Experimental)";
    ui_tooltip = "Only active when VRR Dark Frame Floor > 0.\n"
                 "\n"
                 "OFF (default): dark frames output a flat grey at the floor\n"
                 "level. Clean, no ghosting, but the transition lit->grey->lit\n"
                 "is an abrupt cut which may be more visible as flicker.\n"
                 "\n"
                 "ON: dark frames output lerp(prev_frame, curr_frame, 0.5)\n"
                 "scaled to the floor level. The dark frame contains a 50/50\n"
                 "blend of the previous and current rendered frames, giving\n"
                 "the eye a mid-point image to integrate rather than a hard\n"
                 "grey cut. May further reduce perceived flicker.\n"
                 "\n"
                 "Risk: on fast motion, prev and curr frames are spatially\n"
                 "misaligned -- the blend produces a double-image ghost at\n"
                 "floor brightness. At floor=0.10 this is ~10pct brightness\n"
                 "and usually invisible. At floor=0.20+ it may be noticeable\n"
                 "on fast camera pans. Test with both settings.";
> = false;

uniform bool crt_decay_sine_bfi <
    ui_label = "Sine BFI (VRR Smooth)";
    ui_category = "Phosphor Decay - BFI / Variable MPRT (Experimental)";
    ui_tooltip = "Replaces the hard lit/dark square wave with a smooth cosine\n"
                 "gain curve that rides between litGain and Dark Frame Floor.\n"
                 "\n"
                 "Square wave (off): frame 0 = litGain, frame 1 = darkFloor.\n"
                 "Hard transition every cycle. At 120Hz with frames=2 this is\n"
                 "a 60Hz square wave -- fuses cleanly at locked Hz but under\n"
                 "VRR the irregular cycle boundaries produce visible flicker.\n"
                 "\n"
                 "Sine BFI (on): gain = lerp(darkFloor, litGain, 0.5+0.5*cos(phase)).\n"
                 "All frames output signal -- no hard black cut. The gain rises\n"
                 "and falls smoothly each cycle. Irregular VRR timing shifts the\n"
                 "phase slightly but the eye integrates a smooth waveform rather\n"
                 "than an abrupt cut, making the irregularity much less visible.\n"
                 "\n"
                 "Works best with frames=4: gives 2 frames of ramp-up and\n"
                 "2 frames of ramp-down, creating a clear sine shape.\n"
                 "With frames=2 the endpoints are the same as square wave\n"
                 "but adjacent cycles connect smoothly.\n"
                 "\n"
                 "Trade-off: peak motion clarity is slightly reduced since\n"
                 "the dark frames are never fully at the floor -- they are\n"
                 "on a smooth curve between floor and litGain.\n"
                 "Dark Frame Floor sets the minimum of the sine trough.";
> = false;

uniform bool crt_decay_invert_cycle <
    ui_label = "Invert Cycle (Multi-Lit)";
    ui_category = "Phosphor Decay - BFI / Variable MPRT (Experimental)";
    ui_tooltip = "Inverts the lit/dark ratio: instead of 1 lit + (frames-1) dark,\n"
                 "uses (frames-1) lit + 1 dark.\n"
                 "\n"
                 "Standard (off):  1 lit, N-1 dark. Low duty cycle, maximum clarity.\n"
                 "Inverted (on):   N-1 lit, 1 dark. High duty cycle, brighter image,\n"
                 "                 motion clarity from the single dark frame.\n"
                 "\n"
                 "Only useful at 240Hz+ with frames=3 or 4:\n"
                 "  240Hz frames=3 inverted: 2 lit + 1 dark, 80Hz dark rate, 66pct duty.\n"
                 "  360Hz frames=4 inverted: 3 lit + 1 dark, 90Hz dark rate, 75pct duty.\n"
                 "\n"
                 "At 120Hz with frames=2: no effect -- 1 lit + 1 dark is symmetric.\n"
                 "At 120Hz with frames=3: the 40Hz dark rate causes visible pulsing\n"
                 "regardless of inversion -- do not use at 120Hz with frames > 2.\n"
                 "\n"
                 "Gain is automatically adjusted for the higher duty cycle:\n"
                 "litGain = frames * gain / (frames - 1) so average brightness\n"
                 "is maintained relative to the standard non-inverted calculation.\n"
                 "Has no effect on Fibonacci or Variable MPRT (BB integral).";
> = false;

uniform int crt_decay_duty_ratio <
    ui_type = "combo"; ui_label = "BFI Duty Ratio";
    ui_category = "Phosphor Decay - BFI / Variable MPRT (Experimental)";
    ui_items = "1:1 -- every cycle active (default)\0"
               "1:2 -- active every 2nd cycle\0"
               "1:3 -- active every 3rd cycle\0"
               "1:4 -- active every 4th cycle\0";
    ui_tooltip = "Skips BFI every N cycles, replacing skipped cycles with\n"
                 "unmodified passthrough. Reduces flicker at the cost of clarity.\n"
                 "\n"
                 "1:1 (default): continuous BFI, every cycle active.\n"
                 "1:2: BFI runs one cycle, skips the next. Effective dark rate\n"
                 "     is halved. Flicker amplitude reduced, clarity reduced.\n"
                 "1:3: BFI active 1 in 3 cycles. Even lighter effect.\n"
                 "1:4: BFI active 1 in 4 cycles. Barely noticeable clarity gain.\n"
                 "\n"
                 "The skip counter advances every 'frames' rendered frames,\n"
                 "so the ratio is consistent across all frames-per-cycle settings.\n"
                 "\n"
                 "Works for BFI and Variable MPRT (tubePos off).\n"
                 "Also works with Fibonacci: skipped cycles output unmodified\n"
                 "passthrough instead of decay trails -- intermittent phosphor effect.\n"
                 "For Sine BFI, skipped cycles hard-cut to full brightness.";
> = 0;

uniform bool crt_decay_fg_phase <
    ui_label = "Frame Gen Phase Flip";
    ui_category = "Phosphor Decay - BFI / Variable MPRT (Experimental)";
    ui_tooltip = "For DLSS Frame Generation (or any frame gen where FRAMECOUNT\n"
                 "increments for generated frames).\n"
                 "\n"
                 "With 2-frame BFI, FRAMECOUNT already naturally alternates\n"
                 "real/generated frames between lit and dark phases -- no\n"
                 "multiplier needed.\n"
                 "\n"
                 "If the image appears darker than expected (real frames landing\n"
                 "on the dark phase), enable this to flip the phase by 1 frame.\n"
                 "\n"
                 "LSFG / Nvidia Smooth Motion: leave off -- these run outside\n"
                 "ReShade and FRAMECOUNT does not see their generated frames.";
> = false;

uniform float crt_decay_spike_threshold <
    ui_type = "drag"; ui_label = "Frametime Spike Suppress";
    ui_category = "Phosphor Decay - BFI / Variable MPRT (Experimental)";
    ui_tooltip = "Suppresses BFI output on frames where frametime exceeds this\n"
                 "multiple of the expected frame period, outputting unmodified\n"
                 "passthrough instead.\n"
                 "\n"
                 "Frametime spikes (hitches) cause the display to hold a lit or\n"
                 "dark frame for much longer than expected -- the eye sees a\n"
                 "sudden very bright or very dark flash.\n"
                 "\n"
                 "1.5 = suppress if frame took > 1.5x the expected period.\n"
                 "2.0 = only suppress severe spikes (default).\n"
                 "10.0 = effectively disabled.\n"
                 "\n"
                 "Expected period = 1000ms / display Hz. At 120Hz = 8.33ms,\n"
                 "so threshold 2.0 suppresses frames > 16.67ms.\n"
                 "Set CRT_FRAMETIME_EXPECTED to your target frametime in ms\n"
                 "via the preprocessor (default 8.33 = 120Hz).";
    ui_min = 1.0; ui_max = 10.0; ui_step = 0.1;
> = 10.0;

uniform bool crt_decay_auto_resync <
    ui_label = "BFI Auto-Resync";
    ui_category = "Phosphor Decay - BFI / Variable MPRT (Experimental)";
    ui_tooltip = "Monitors average luminance of lit vs dark frames.\n"
                 "If the dark frame becomes significantly brighter than expected\n"
                 "(indicating the BFI phase has flipped due to a dropped frame\n"
                 "or VSync hitch), automatically corrects the phase by 1 frame.\n"
                 "\n"
                 "Fixes the permanent insane flicker that occurs in some games\n"
                 "(e.g. Riven at 120Hz with VSync) after a frame timing anomaly.\n"
                 "\n"
                 "Leave off if your game has stable frame delivery -- the monitor\n"
                 "adds a small per-frame luminance sample and comparison.\n"
                 "Enable if you experience sudden unrecoverable BFI flicker.";
> = false;

uniform float crt_decay_scene_threshold <
    ui_type = "drag"; ui_label = "Scene Change Threshold (MPRT only)";
    ui_category = "Phosphor Decay - BFI / Variable MPRT (Experimental)";
    ui_tooltip = "Variable MPRT only. Luminance delta that triggers a scene-change bypass.\n"
                 "On a hard cut to a much brighter scene (e.g. ground to clouds),\n"
                 "history frames hold stale dark values, diluting the bright current\n"
                 "frame and causing a 2-3 frame grey flash.\n"
                 "When per-pixel luma difference between current and prev1 exceeds\n"
                 "this threshold, the overlap integral is skipped and the current\n"
                 "frame passes through at full gain for that pixel.\n"
                 "1.0 = disabled (default). 0.20 = catches most hard cuts.\n"
                 "Lower = more aggressive bypass. Has no effect in BFI or Fibonacci.";
    ui_min = 0.05; ui_max = 1.0; ui_step = 0.01;
> = 1.0;

uniform bool crt_decay_tube_pos <
    ui_label = "Raster Sweep - TubePos (MPRT only)";
    ui_category = "Phosphor Decay - BFI / Variable MPRT (Experimental)";
    ui_tooltip = "Variable MPRT only. Spatially-varying phase simulating the CRT beam\n"
                 "sweeping top-to-bottom.\n"
                 "120Hz: KEEP DISABLED. The sweep period equals the frame period so the\n"
                 "gradient band appears frozen on screen -- a static bright or\n"
                 "semi-transparent band. This is not a bug; it is physics.\n"
                 "240Hz+: enable for a subtle authentic rolling gradient.\n"
                 "When disabled, tubePos is fixed at 0.5 (uniform, no artifact).\n"
                 "Has no effect in BFI or Fibonacci.";
> = false;
#endif

// -- Phosphor Decay - Variable MPRT only ---------------------

// ============================================================
// Uniforms -- Interference
// ============================================================

#if ENABLE_INTERFERENCE
uniform float crt_hum_intensity <
    ui_type = "drag"; ui_label = "Hum Bar Intensity";
    ui_category = "Interference";
    ui_tooltip = "AC mains interference -- slow scrolling brightness gradient.\n"
                 "Caused by 50/60Hz electrical pickup in poorly shielded CRTs.\n"
                 "Positive = dark band scrolls up. Negative = bright band scrolls up.\n"
                 "0.0 = disabled. 0.1-0.2 = subtle. 0.5+ = strong.";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_hum_speed <
    ui_type = "drag"; ui_label = "Hum Bar Speed";
    ui_category = "Interference";
    ui_tooltip = "Scroll speed. 50 = typical 50Hz PAL. 60 = 60Hz NTSC.";
    ui_min = 1.0; ui_max = 200.0; ui_step = 1.0;
> = 50.0;

uniform float crt_hsync_strength <
    ui_type = "drag"; ui_label = "H-Sync Instability";
    ui_category = "Interference";
    ui_tooltip = "Occasional brief horizontal displacement of individual scanlines,\n"
                 "simulating a weak H-sync signal losing lock momentarily.\n"
                 "Unlike wiggle (continuous whole-frame oscillation), this fires\n"
                 "probabilistically on random rows -- rare, sharp, localised.\n"
                 "Slightly stronger near top of screen (authentic sync behaviour).\n"
                 "Resolution-scaled: same value = same pixel displacement at any res.\n"
                 "0.0 = disabled. 0.002-0.005 = rare subtle glitch. 0.01+ = frequent.";
    ui_min = 0.0; ui_max = 0.03; ui_step = 0.001;
> = 0.0;

uniform float crt_hsync_rate <
    ui_type = "drag"; ui_label = "H-Sync Glitch Rate";
    ui_category = "Interference";
    ui_tooltip = "How frequently H-sync glitches occur. Higher = more rows affected\n"
                 "per frame. 0.01 = very rare (1% of rows). 0.1 = frequent (10%).";
    ui_min = 0.005; ui_max = 0.2; ui_step = 0.005;
> = 0.02;

uniform float crt_wiggle_strength <
    ui_type = "drag"; ui_label = "Wiggle Strength";
    ui_category = "Interference";
    ui_tooltip = "Horizontal UV displacement per scanline row.\n"
                 "Scaled by resolution so 1080p value 0.0012 (NewPixie default)\n"
                 "produces the same pixel displacement at any resolution.\n"
                 "At 4K start around 0.0001-0.0003. At 1080p 0.0005-0.0012.\n"
                 "0.0 = disabled.";
    ui_min = 0.0; ui_max = 0.005; ui_step = 0.0001;
> = 0.0;

uniform float crt_wiggle_speed <
    ui_type = "drag"; ui_label = "Wiggle Speed";
    ui_category = "Interference";
    ui_tooltip = "How fast the interference pattern evolves over time.";
    ui_min = 0.0; ui_max = 4.0; ui_step = 0.1;
> = 1.0;

uniform float crt_scanline_jitter <
    ui_type = "drag"; ui_label = "Scanline Jitter";
    ui_category = "Interference";
    ui_tooltip = "Per-scanline vertical displacement in pixels.\n"
                 "Simulates raster instability -- each row offset by a small\n"
                 "random amount that drifts slowly over time.\n"
                 "0.0 = disabled. 0.3-0.8 = subtle. 1.0-2.0 = noticeable.";
    ui_min = 0.0; ui_max = 3.0; ui_step = 0.05;
> = 0.0;

uniform float crt_flicker_strength <
    ui_type = "drag"; ui_label = "Rolling Scanlines Strength";
    ui_category = "Interference";
    ui_tooltip = "Rolling scanline scroll speed. 0.0 = no rolling scanlines.\n"
                 "Higher = faster scroll. 0.5 = slow. 2.0+ = fast.\n"
                 "Amplitude fixed at 0.18 matching NewPixie.";
    ui_min = 0.0; ui_max = 4.0; ui_step = 0.05;
> = 0.0;

uniform float crt_accum_modulate <
    ui_type = "drag"; ui_label = "Accumulate Modulation";
    ui_category = "Interference";
    ui_tooltip = "Phosphor afterglow accumulation (NewPixie approach).\n"
                 "Blends each frame with a decayed copy of the previous frame:\n"
                 "output = max(prev * modulate, current * 0.96)\n"
                 "Bright content trails and persists for several frames.\n"
                 "0.0 = disabled. 0.5-0.7 = subtle trail. 0.9+ = heavy ghosting.\n"
                 "Implemented as a dedicated accumulation pass.";
    ui_min = 0.0; ui_max = 0.95; ui_step = 0.01;
> = 0.0;

uniform float crt_magnetic_strength <
    ui_type = "drag"; ui_label = "Magnetic Interference Strength";
    ui_category = "Interference";
    ui_tooltip = "Persistent magnetic field interference -- radial hue rotation\n"
                 "around a focal point, creating characteristic rainbow rings.\n"
                 "Simulates a magnet or speaker placed near the CRT.\n"
                 "0.0 = disabled. 0.1-0.3 = subtle. 0.5+ = strong colour shift.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float crt_magnetic_x <
    ui_type = "drag"; ui_label = "Magnetic Source X";
    ui_category = "Interference";
    ui_tooltip = "Horizontal position of the magnetic interference source.\n"
                 "0.0 = left edge. 0.5 = centre. 1.0 = right edge.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.25;

uniform float crt_magnetic_y <
    ui_type = "drag"; ui_label = "Magnetic Source Y";
    ui_category = "Interference";
    ui_tooltip = "Vertical position of the magnetic interference source.\n"
                 "0.0 = top. 0.5 = centre. 1.0 = bottom.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.25;

uniform float crt_magnetic_radius <
    ui_type = "drag"; ui_label = "Magnetic Radius";
    ui_category = "Interference";
    ui_tooltip = "Radius of the interference rings. Larger = wider rings,\n"
                 "effect extends further from the source.";
    ui_min = 0.1; ui_max = 2.0; ui_step = 0.05;
> = 0.5;

uniform float crt_magnetic_speed <
    ui_type = "drag"; ui_label = "Magnetic Animation Speed";
    ui_category = "Interference";
    ui_tooltip = "Speed of the ring animation -- rings slowly pulse outward.\n"
                 "0.0 = static. 1.0 = slow drift. 3.0+ = fast pulsing.";
    ui_min = 0.0; ui_max = 5.0; ui_step = 0.1;
> = 1.0;

uniform float crt_dot_crawl <
    ui_type = "drag"; ui_label = "Dot Crawl";
    ui_category = "Interference";
    ui_tooltip = "NTSC composite colour subcarrier interference pattern.\n"
                 "Creates a moving diagonal noise at luma-chroma boundaries,\n"
                 "characteristic of 240p content through composite video.\n"
                 "Most visible on coloured edges against contrasting backgrounds.\n"
                 "0.0 = disabled. 0.02-0.05 = subtle. 0.1+ = strong.";
    ui_min = 0.0; ui_max = 0.2; ui_step = 0.005;
> = 0.0;

uniform float crt_ghost_strength <
    ui_type = "drag"; ui_label = "Ghost Strength";
    ui_category = "Interference";
    ui_tooltip = "Chromatic ghost image displaced from source.\n"
                 "Very sensitive -- start at 0.005-0.01 for subtle effect.\n"
                 "NewPixie hardcoded value is 0.15 (ghs) at 1080p.\n"
                 "At 4K/5K use much lower values: 0.005-0.02.\n"
                 "0.0 = disabled.";
    ui_min = 0.0; ui_max = 0.3; ui_step = 0.005;
> = 0.0;

uniform float crt_ghost_speed <
    ui_type = "drag"; ui_label = "Ghost Speed";
    ui_category = "Interference";
    ui_tooltip = "Speed of the animated ghost wobble. Default 1.0 matches NewPixie.\n"
                 "The wobble is very small -- main ghost position is a fixed offset.";
    ui_min = 0.0; ui_max = 4.0; ui_step = 0.1;
> = 1.0;
#endif // ENABLE_INTERFERENCE

// Uniforms -- Pipeline (Soop integration)
// Only relevant when PIPELINE=1 (scRGB) or PIPELINE=2 (HDR10)
// ============================================================

#if PIPELINE >= 1
uniform float crt_soop_peak_nits <
    ui_type = "drag"; ui_label = "Display Peak Brightness (nits)";
    ui_category = "Pipeline";
    ui_tooltip = "Peak luminance of your display in nits.\n"
                 "Sony A95L 77\": 1400\n"
                 "Used to set the Reinhard white point for scRGB compression.\n"
                 "Only active when PIPELINE=1 or PIPELINE=2.";
    ui_min = 100.0; ui_max = 4000.0; ui_step = 10.0;
> = 1400.0;

uniform float crt_soop_shadow_gamma <
    ui_type = "drag"; ui_label = "Shadow Gamma";
    ui_category = "Pipeline";
    ui_tooltip = "Gamma lift applied before Reinhard compression.\n"
                 "1.0 = linear (shadows compressed more, highlights cleanest).\n"
                 "1.4 = moderate default, good balance for QD-OLED.\n"
                 "2.0 = shadows better preserved, highlights double-compressed.\n"
                 "Only active when PIPELINE=1 or PIPELINE=2.";
    ui_min = 1.0; ui_max = 2.4; ui_step = 0.05;
> = 1.4;
#endif

#if PIPELINE == 2
uniform float crt_soop_hdr10_peak_nits <
    ui_type = "drag"; ui_label = "HDR10 Content Peak (nits)";
    ui_category = "Pipeline";
    ui_tooltip = "Peak brightness of the HDR10 content in nits.\n"
                 "Typically 1000 for most HDR10 content.\n"
                 "Only active when PIPELINE=2 (HDR10).";
    ui_min = 100.0; ui_max = 10000.0; ui_step = 10.0;
> = 1000.0;
#endif
uniform float crt_timer < source = "timer"; >;

// ============================================================
// Uniforms -- Anti Burn-In
// ============================================================

#if ENABLE_BURNIN_PHASE
uniform float crt_burnin_phase_amp <
    ui_type = "drag"; ui_label = "Phase Shift Amplitude (pixels)";
    ui_category = "Anti Burn-In";
    ui_tooltip = "How many pixels the mask and scanline patterns shift during each cycle.\n"
                 "1-2 pixels is enough to distribute phosphor wear.\n"
                 "Set ENABLE_BURNIN_PHASE=0 in preprocessor to disable entirely.";
    ui_min = 0.0; ui_max = 6.0; ui_step = 0.5;
> = 2.0;

uniform float crt_burnin_phase_period <
    ui_type = "drag"; ui_label = "Phase Shift Period (minutes)";
    ui_category = "Anti Burn-In";
    ui_tooltip = "How long one full phase cycle takes in minutes.\n"
                 "Longer = slower, less noticeable movement.\n"
                 "Recommended: 3-5 minutes.";
    ui_min = 0.5; ui_max = 20.0; ui_step = 0.5;
> = 3.0;
#endif

#if ENABLE_BURNIN_ORBIT
uniform float crt_burnin_orbit_radius <
    ui_type = "drag"; ui_label = "Pixel Orbit Radius (pixels)";
    ui_category = "Anti Burn-In";
    ui_tooltip = "Radius of the slow circular pixel shift applied to the entire image.\n"
                 "1-2 pixels is imperceptible but effective for burn-in protection.\n"
                 "Set ENABLE_BURNIN_ORBIT=0 in preprocessor to disable entirely.";
    ui_min = 0.0; ui_max = 4.0; ui_step = 0.5;
> = 1.0;

uniform float crt_burnin_orbit_period <
    ui_type = "drag"; ui_label = "Pixel Orbit Period (minutes)";
    ui_category = "Anti Burn-In";
    ui_tooltip = "How long one full orbit cycle takes in minutes.\n"
                 "Use a different value than the phase period to avoid synchronisation.\n"
                 "Recommended: 7-10 minutes.";
    ui_min = 0.5; ui_max = 30.0; ui_step = 0.5;
> = 7.0;
#endif

// ============================================================
// Intermediate textures
// ============================================================

// Pre-blur H pass output
// PREBLUR_RESOLUTION: 1 = full res (default, acts as AA). 2+ = reduced resolution.
texture2D crt_preblur_h_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH  / PREBLUR_RESOLUTION;
    Height = BUFFER_HEIGHT / PREBLUR_RESOLUTION;
    Format = RGBA16F;
};
sampler2D crt_preblur_h_sampler
{
    Texture   = crt_preblur_h_tex;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = NONE;
};

// Pre-blur V pass output (= final pre-blurred source)
texture2D crt_preblur_v_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH  / PREBLUR_RESOLUTION;
    Height = BUFFER_HEIGHT / PREBLUR_RESOLUTION;
    Format = RGBA16F;
};
sampler2D crt_preblur_v_sampler
{
    Texture   = crt_preblur_v_tex;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = NONE;
};

// Edge blur writes directly to backbuffer -- no intermediate texture needed

// ============================================================
// Film Grain: Poisson lookup table (compute shader path)
// 256 color levels x 1024 trials -- built once per frame by CS.
// Stores fraction of halide crystals exposed at each luminance level.
// Falls back to analytical Gaussian path when compute not available.
// ============================================================

// Phosphor persistence: previous frame storage
#if ENABLE_DECAY
// Phase correction: stores cycle index (RGBA8 -- R8 has driver issues on ReShade 6.x)
texture2D crt_decay_phase_tex < pooled = false; >
{
    Width  = 1;
    Height = 1;
    Format = RGBA8;
};
sampler2D crt_decay_phase_sampler { Texture = crt_decay_phase_tex; };

// Auto-resync luminance monitor: two 1x1 textures for lit and dark frame EMA.
// Luma monitor: ping-pong textures so the PS can read previous frame
// while writing current frame (avoids same-pass read/write error).
texture2D crt_decay_luma_lit_tex  < pooled = false; > { Width=1; Height=1; Format=R16F; };
texture2D crt_decay_luma_dark_tex < pooled = false; > { Width=1; Height=1; Format=R16F; };
texture2D crt_decay_luma_lit_prev_tex  < pooled = false; > { Width=1; Height=1; Format=R16F; };
texture2D crt_decay_luma_dark_prev_tex < pooled = false; > { Width=1; Height=1; Format=R16F; };
sampler2D crt_decay_luma_lit_sampler      { Texture=crt_decay_luma_lit_tex;       MipFilter=NONE; MinFilter=POINT; MagFilter=POINT; };
sampler2D crt_decay_luma_dark_sampler     { Texture=crt_decay_luma_dark_tex;      MipFilter=NONE; MinFilter=POINT; MagFilter=POINT; };
sampler2D crt_decay_luma_lit_prev_samp    { Texture=crt_decay_luma_lit_prev_tex;  MipFilter=NONE; MinFilter=POINT; MagFilter=POINT; };
sampler2D crt_decay_luma_dark_prev_samp   { Texture=crt_decay_luma_dark_prev_tex; MipFilter=NONE; MinFilter=POINT; MagFilter=POINT; };

// Variable MPRT: two history frames for brightness budget
texture2D crt_decay_prev1_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D crt_decay_prev1_sampler { Texture = crt_decay_prev1_tex; };

texture2D crt_decay_prev2_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D crt_decay_prev2_sampler { Texture = crt_decay_prev2_tex; };
// Raw game frame captured before decay runs -- used for clean history comparison.
// The prev1/prev2 textures capture post-decay output (alternating lit/black),
// which breaks scene-change detection. This texture holds the unmodified signal.
texture2D crt_decay_raw_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D crt_decay_raw_sampler { Texture = crt_decay_raw_tex; };
#endif

#if ENABLE_PERSISTENCE
texture2D crt_persistence_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D crt_persistence_samp
{
    Texture   = crt_persistence_tex;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
};
#endif

#if ENABLE_GRAIN
// Grain delta texture: stores (grained - original) delta only
texture2D crt_grain_raw_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D crt_grain_raw_samp { Texture = crt_grain_raw_tex; };


// Pre-grain snapshot: clean backbuffer before grain is applied
texture2D crt_pregrain_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D crt_pregrain_samp { Texture = crt_pregrain_tex; };
#endif // ENABLE_GRAIN

// Accumulation texture for interference afterglow (NewPixie accumulate modulation)
#if ENABLE_INTERFERENCE
texture2D crt_accum_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA8;
};
sampler2D crt_accum_samp { Texture = crt_accum_tex; MagFilter = LINEAR; MinFilter = LINEAR; };
#endif // ENABLE_INTERFERENCE

// Glow horizontal blur output
texture2D crt_glow_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH  / GLOW_RESOLUTION;
    Height = BUFFER_HEIGHT / GLOW_RESOLUTION;
    Format = RGBA16F;
};
sampler2D crt_glow_sampler
{
    Texture   = crt_glow_tex;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = NONE;
};

// Glow vertical blur output (combined H+V glow, sampled in main pass)
// Resolution set by GLOW_RESOLUTION preprocessor (default 2 = half res).
// Glow is a wide low-frequency effect -- reduced resolution is imperceptible.
texture2D crt_glow_v_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH  / GLOW_RESOLUTION;
    Height = BUFFER_HEIGHT / GLOW_RESOLUTION;
    Format = RGBA16F;
};
sampler2D crt_glow_v_sampler
{
    Texture   = crt_glow_v_tex;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = NONE;
};

// Wide (secondary) glow textures -- run at 2x lower resolution than tight glow.
// Large-area bloom for bright surfaces, complementing the tight per-element glow.
texture2D crt_glow_wide_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH  / (GLOW_RESOLUTION * 2);
    Height = BUFFER_HEIGHT / (GLOW_RESOLUTION * 2);
    Format = RGBA16F;
};
sampler2D crt_glow_wide_sampler
{
    Texture   = crt_glow_wide_tex;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = NONE;
};
texture2D crt_glow_wide_v_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH  / (GLOW_RESOLUTION * 2);
    Height = BUFFER_HEIGHT / (GLOW_RESOLUTION * 2);
    Format = RGBA16F;
};
sampler2D crt_glow_wide_v_sampler
{
    Texture   = crt_glow_wide_v_tex;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = NONE;
};

// Halation blur output -- resolution set by HALATION_RESOLUTION preprocessor
// HALATION_RESOLUTION=4 -> quarter res (cheapest, may alias on movement)
// HALATION_RESOLUTION=2 -> half res (good balance, recommended)
// HALATION_RESOLUTION=1 -> full res (best quality, most expensive)
#if ENABLE_HALATION
texture2D crt_halation_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH  / HALATION_RESOLUTION;
    Height = BUFFER_HEIGHT / HALATION_RESOLUTION;
    Format = RGBA16F;
};
sampler2D crt_halation_sampler
{
    Texture   = crt_halation_tex;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
};
// Vertical halation pass output (anisotropy support)
texture2D crt_halation_v_tex < pooled = false; >
{
    Width  = BUFFER_WIDTH  / HALATION_RESOLUTION;
    Height = BUFFER_HEIGHT / HALATION_RESOLUTION;
    Format = RGBA16F;
};
sampler2D crt_halation_v_sampler
{
    Texture   = crt_halation_v_tex;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
};
#endif

// ============================================================
// Megatron cubic Bezier
// ============================================================

static const float4x4 kCubicBezier = float4x4(
     1.0f,  0.0f,  0.0f,  0.0f,
    -3.0f,  3.0f,  0.0f,  0.0f,
     3.0f, -6.0f,  3.0f,  0.0f,
    -1.0f,  3.0f, -3.0f,  1.0f);

float Bezier(float t, float4 cp)
{
    float4 tv = float4(1.0, t, t*t, t*t*t);
    return dot(tv, mul(kCubicBezier, cp));
}

// ============================================================
// Pipeline: Soop-compatible HDR sandwich functions
// Ported from smolbbsoop by Violet Cleathero (MIT)
// Modified: runtime peak_nits and shadow_gamma uniforms
// ============================================================

#if PIPELINE >= 1

// PQ constants for HDR10
#define PQ_m1 0.1593017578125
#define PQ_m2 78.84375
#define PQ_c1 0.8359375
#define PQ_c2 18.8515625
#define PQ_c3 18.6875

float3 soop_srgb_to_linear(float3 x)
{
    return x < 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
}
float3 soop_linear_to_srgb(float3 x)
{
    return x < 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
}

// scRGB Reinhard forward (Before pass)
float3 soop_reinhard(float3 x, float peak_nits, float shadow_gamma)
{
    float W = peak_nits / 80.0; // scRGB peak
    x = pow(max(x, 0.0), 1.0 / shadow_gamma);
    return (x * (1.0 + x / (W * W))) / (1.0 + x);
}

// scRGB Inverse Reinhard (After pass)
float3 soop_inv_reinhard(float3 x, float shadow_gamma)
{
    x = clamp(x, 0.0, 1.0);
    float maxCh = max(max(x.r, x.g), x.b);
    if (maxCh >= 1.0) x *= (0.9999 / maxCh);
    x = x / (1.0 - x);
    return pow(max(x, 0.0), shadow_gamma);
}

#if PIPELINE == 2
// HDR10 PQ decode to linear
float3 soop_pq_to_linear(float3 x, float content_peak_nits)
{
    float3 xpow = pow(max(x, 0.0), 1.0 / PQ_m2);
    float3 num  = max(xpow - PQ_c1, 0.0);
    float3 den  = max(PQ_c2 - PQ_c3 * xpow, 1e-10);
    float  S    = 20375.99 * pow(content_peak_nits, -0.995);
    return pow(num / den, 1.0 / PQ_m1) * S;
}

// Linear to HDR10 PQ encode
float3 soop_linear_to_pq(float3 x, float content_peak_nits)
{
    float  S       = 0.003789 * content_peak_nits;
    float3 x_sc    = x * S;
    float3 Y       = clamp(x_sc / 80.0, 0.0, 1.0);
    float3 Ym1     = pow(Y, PQ_m1);
    float3 num     = PQ_c1 + PQ_c2 * Ym1;
    float3 den     = 1.0 + PQ_c3 * Ym1;
    return pow(num / den, PQ_m2);
}

// HDR10 simple Reinhard (no white point -- HDR10 path is already in linear after decode)
float3 soop_reinhard_simple(float3 x)
{
    return x / (1.0 + x);
}
float3 soop_inv_reinhard_simple(float3 x)
{
    x = clamp(x, 0.0, 1.0);
    return x / (1.0 - x);
}
#endif // PIPELINE == 2

#endif // PIPELINE >= 1

// ============================================================
// Phosphor profile correction
// Matrices from Guest Advanced CRT (guest.r, GPL)
// RGB->XYZ input matrices (CRT phosphor primaries)
// XYZ->RGB output matrices (display gamut)
// ============================================================

#if ENABLE_PHOSPHOR
// ── Phosphor input matrices: RGB -> XYZ ─────────────────────────────────────
// Each matrix converts from the CRT's native phosphor primaries to CIE XYZ.
// All computed from CIE xy chromaticity coordinates via the standard method:
// M = [R|G|B] * diag(solve([R|G|B], W)) where R,G,B are primary XYZ columns
// and W is the white point XYZ.
// White point is D65 (x=0.3127, y=0.3290) unless noted.
//
// Profile            R_xy        G_xy        B_xy        White
// EBU (PAL)         0.640,0.330 0.290,0.600 0.150,0.060 D65
// P22               0.625,0.340 0.280,0.595 0.155,0.070 D65
// SMPTE-C / BVM-D   0.630,0.340 0.310,0.595 0.155,0.070 D65
// Trinitron         0.621,0.341 0.295,0.605 0.150,0.063 D65 (measured)
// NTSC 1953         0.670,0.330 0.210,0.710 0.140,0.080 Illum C (x=0.3101,y=0.3162)
// NTSC 1953 D93     0.670,0.330 0.210,0.710 0.140,0.080 D93 (x=0.2848,y=0.2932)

// EBU (PAL) -- European Broadcasting Union Tech 3213.
// Used by PAL CRTs from 1970s onwards. Green slightly more yellow than sRGB.
static const float3x3 kPhosphor_EBU     = float3x3(0.430554,0.222004,0.020182, 0.341550,0.706655,0.129553, 0.178352,0.071341,0.939322);

// P22 -- common US consumer CRT phosphor set (ca. 1970s-90s NTSC sets).
// Slightly warmer red, cooler green than EBU.
static const float3x3 kPhosphor_P22     = float3x3(0.449662,0.244616,0.025181, 0.316256,0.672044,0.141186, 0.184538,0.083340,0.922691);

// SMPTE-C (1987) -- North American broadcast standard, also used by Sony BVM-D
// broadcast reference monitors and Philips European CRTs (same chromaticities).
// Most PS1/PS2/N64 era games were mastered on BVM-D.
static const float3x3 kPhosphor_SMPTEC  = float3x3(0.393521,0.212376,0.018739, 0.365258,0.701060,0.111934, 0.191677,0.086564,0.958385);

// Sony Trinitron -- measured phosphor chromaticities from Trinitron tubes.
// Slightly more saturated green, deeper blue than standard EBU.
static const float3x3 kPhosphor_Trinitron = float3x3(0.435625,0.239208,0.026657, 0.333914,0.684807,0.113191, 0.180917,0.075985,0.949210);

// NTSC 1953 -- original FCC NTSC specification with Illuminant C white point.
// Very wide gamut (especially saturated reds and greens), but Illuminant C
// white (~6774K) is warmer than D65. The widest gamut CRT standard.
// Games did NOT target this -- it reflects early 1950s TV receiver phosphors.
static const float3x3 kPhosphor_NTSC1953 = float3x3(0.606937,0.298939,0.000000, 0.173509,0.586625,0.066099, 0.200263,0.114436,1.115748);

// NTSC 1953 at D93 white point -- Japanese CRT monitors (~9300K).
// Japan never adopted SMPTE-C, continuing to use 1953 NTSC primaries
// but with a cooler 9300K white point standard. Very blue whites.
// Most relevant for SNES, Mega Drive, and Saturn era content as seen
// in Japan on consumer CRTs of that period.
static const float3x3 kPhosphor_NTSC1953_D93 = float3x3(0.551060,0.271418,0.000000, 0.173843,0.587755,0.066226, 0.246448,0.140827,1.373065);

// ── Display output matrices: XYZ -> RGB ─────────────────────────────────────
// Output: XYZ -> RGB for each display gamut
static const float3x3 kGamut_sRGB    = float3x3( 3.240970,-0.969244, 0.055630,-1.537383, 1.875968,-0.203977,-0.498611, 0.041555, 1.056972);
static const float3x3 kGamut_Modern  = float3x3( 2.791723,-0.894766, 0.041678,-1.173165, 1.815586,-0.130886,-0.440973, 0.032000, 1.002034);
static const float3x3 kGamut_DCI     = float3x3( 2.493497,-0.829489, 0.035846,-0.931384, 1.762664,-0.076172,-0.402711, 0.023625, 0.956885);
static const float3x3 kGamut_Adobe   = float3x3( 2.041588,-0.969244, 0.013444,-0.565007, 1.875968,-0.118360,-0.344731, 0.041555, 1.015175);
static const float3x3 kGamut_Rec2020 = float3x3( 1.716651,-0.666684, 0.017640,-0.355671, 1.616481,-0.042771,-0.253366, 0.015769, 0.942103);

float3 apply_phosphor(float3 c)
{
    // Select input phosphor matrix (CRT primaries -> XYZ)
    float3x3 m_in;
    if      (crt_phosphor_profile == 0) m_in = kPhosphor_EBU;
    else if (crt_phosphor_profile == 1) m_in = kPhosphor_P22;
    else if (crt_phosphor_profile == 2) m_in = kPhosphor_SMPTEC;
    else if (crt_phosphor_profile == 3) m_in = kPhosphor_Trinitron;
    else if (crt_phosphor_profile == 4) m_in = kPhosphor_NTSC1953;
    else                                m_in = kPhosphor_NTSC1953_D93;

    // Select output display gamut matrix (XYZ -> display RGB)
    float3x3 m_out;
    if      (crt_display_gamut == 0) m_out = kGamut_sRGB;
    else if (crt_display_gamut == 1) m_out = kGamut_Modern;
    else if (crt_display_gamut == 2) m_out = kGamut_DCI;
    else if (crt_display_gamut == 3) m_out = kGamut_Adobe;
    else                             m_out = kGamut_Rec2020;

    // Decode to linear using sRGB piecewise TRC (correct IEC 61966-2-1).
    // Defined inline because glin/genc macros are not yet in scope here.
    // sRGB decode: linear = c/12.92 if c <= 0.04045, else ((c+0.055)/1.055)^2.4
    float3 c_lin = (c <= 0.04045)
                 ? c / 12.92
                 : pow((c + 0.055) / 1.055, 2.4);
    float3 xyz   = mul(c_lin, m_in);   // CRT phosphor RGB -> XYZ
    float3 rgb   = mul(xyz,   m_out);  // XYZ -> display RGB
    // sRGB encode: c/12.92 if linear <= 0.0031308, else 1.055*linear^(1/2.4)-0.055
    float3 rgb_s = max(rgb, 0.0);
    float3 c_out = (rgb_s <= 0.0031308)
                 ? rgb_s * 12.92
                 : 1.055 * pow(rgb_s, 1.0/2.4) - 0.055;

    return lerp(c, c_out, crt_phosphor_strength);
}
#endif

// ============================================================
// Colour temperature chromatic adaptation (D65 to D55 / D93)
// Matrices from CRT Guest Advanced (GPL v2+)
// ============================================================
#if ENABLE_PHOSPHOR
static const float3x3 kD65_to_D55 = float3x3(
    0.485034, 0.250096, 0.022736,
    0.348896, 0.697791, 0.116299,
    0.130282, 0.052113, 0.686154);

static const float3x3 kD65_to_D93 = float3x3(
    0.341275, 0.175970, 0.015997,
    0.364617, 0.729234, 0.121539,
    0.236989, 0.094796, 1.248144);

// Standard XYZ to sRGB (D65) for colour temperature output re-encoding
static const float3x3 kXYZ_to_sRGB = float3x3(
     3.240970,-1.537383,-0.498611,
    -0.969244, 1.875968, 0.041555,
     0.055630,-0.203977, 1.056972);
#endif

// ============================================================
// Hue rotation helper (for magnetic interference)
// ============================================================
float3 hue_rotate(float3 c, float angle)
{
    // Rotate hue by angle (radians) using RGB rotation matrix
    float s = sin(angle);
    float cs = cos(angle);
    float3x3 m = float3x3(
        cs + (1.0-cs)/3.0,        (1.0-cs)/3.0 - s*0.57735, (1.0-cs)/3.0 + s*0.57735,
        (1.0-cs)/3.0 + s*0.57735, cs + (1.0-cs)/3.0,         (1.0-cs)/3.0 - s*0.57735,
        (1.0-cs)/3.0 - s*0.57735, (1.0-cs)/3.0 + s*0.57735,  cs + (1.0-cs)/3.0);
    return max(mul(c, m), 0.0);
}

// ============================================================
// Megatron BCS in Yxy space
// ============================================================

static const float4 kTopBrightness = float4(0.0, 1.0, 1.0, 1.0);
static const float4 kMidBrightness = float4(0.0, 1.0/3.0, 2.0/3.0, 1.0);
static const float4 kBotBrightness = float4(0.0, 0.0, 0.0, 1.0);
static const float4 kTopContrast   = float4(0.0, 0.0, 1.0, 1.0);
static const float4 kMidContrast   = float4(0.0, 1.0/3.0, 2.0/3.0, 1.0);
static const float4 kBotContrast   = float4(0.0, 1.0, 0.0, 1.0);

static const float3x3 kXYZ_to_709 = float3x3(
     3.240970, -1.537383, -0.498611,
    -0.969244,  1.875968,  0.041555,
     0.055630, -0.203977,  1.056972);
static const float3x3 k709_to_XYZ = float3x3(
    0.412391, 0.357584, 0.180481,
    0.212639, 0.715169, 0.072192,
    0.019331, 0.119195, 0.950532);

float3 XYZtoYxy(float3 XYZ)
{
    float s = XYZ.r + XYZ.g + XYZ.b;
    return float3(XYZ.g, (s<=0.0)?0.3805:XYZ.r/s, (s<=0.0)?0.3769:XYZ.g/s);
}
float3 YxytoXYZ(float3 Yxy)
{
    float Xs = Yxy.r * (Yxy.g / max(Yxy.b, 1e-5));
    float nz = (Yxy.r <= 0.0) ? 0.0 : 1.0;
    return float3(nz,nz,nz) * float3(Xs, Yxy.r, (Xs/max(Yxy.g,1e-5)) - Xs - Yxy.r);
}

// Colour temperature: warm/cool shift relative to D65
// Uses a cross-channel matrix approach similar to Megatron's white balance.
// Negative = warm (less blue, more red), positive = cool (more blue, less red).
// Applied in linear space, luminance-preserving via per-channel scaling.
float3 apply_colour_temp(float3 c, float temp)
{
    if (abs(temp) < 0.001) return c;

    // D65 reference RGB multipliers for warm (-1) and cool (+1) extremes
    // Derived from Kelvin approximation: warm~2700K, cool~12000K
    // These multipliers are relative to D65 (1,1,1)
    float3 warm = float3(1.12, 1.00, 0.72); // ~3200K relative to D65
    float3 cool = float3(0.82, 0.97, 1.22); // ~9000K relative to D65

    float3 wb = (temp < 0.0)
        ? lerp(float3(1.0, 1.0, 1.0), warm, -temp)
        : lerp(float3(1.0, 1.0, 1.0), cool,  temp);

    float3 shifted = c * wb;

    // Preserve luminance so temperature shift doesn't change brightness
    float luma_before = dot(max(c,       0.0), float3(0.2126, 0.7152, 0.0722));
    float luma_after  = dot(max(shifted, 0.0), float3(0.2126, 0.7152, 0.0722));
    shifted = (luma_after > 0.0001) ? shifted * (luma_before / luma_after) : shifted;

    return shifted;
}

float3 apply_bcs(float3 c, float brightness, float contrast, float saturation)
{
#if LINEAR_HDR_INPUT
    // --------------------------------------------------------
    // Linear HDR path (Luma / raw scRGB)
    // Avoids XYZ/Yxy matrix math which breaks when channel
    // values are >> 1.0. Operates directly in linear RGB.
    // Brightness/contrast use luma-normalised curves so
    // hue is preserved. Saturation is a simple luma lerp.
    // --------------------------------------------------------
    // Normalise against display peak so BCS never pushes above peak nits
    // LINEAR_HDR_PEAK = display_peak_nits / 80 (scRGB units)
    float3 c_safe  = max(c, 0.0);
    float  luma_in = dot(c_safe, float3(0.2126, 0.7152, 0.0722));

    // Use peak nits ceiling as normalisation reference
    // This ensures Bezier operates on [0,1] relative to display peak
    // and the reconstruction cannot exceed that peak
    float  L_ref  = float(LINEAR_HDR_PEAK_NITS) / 80.0; // convert nits to scRGB units
    float  L_norm = luma_in / L_ref;
    float  L_g    = pow(clamp(L_norm, 0.0, 1.0), 1.0/2.4);

    float L_b = (brightness >= 0.0)
        ? Bezier(L_g, lerp(kMidBrightness, kTopBrightness, brightness))
        : Bezier(L_g, lerp(kMidBrightness, kBotBrightness, -brightness));
    float L_c = (contrast >= 0.0)
        ? Bezier(L_b, lerp(kMidContrast, kTopContrast, contrast))
        : Bezier(L_b, lerp(kMidContrast, kBotContrast, -contrast));

    float L_out = pow(max(L_c, 0.0), 2.4) * L_ref;

    // Scale RGB by luma ratio to preserve hue
    float3 rgb = (luma_in > 0.0001) ? c_safe * (L_out / luma_in) : c_safe;

    // Saturation: lerp toward luma, clamped to display peak
    float  sat = 0.5 + saturation * 0.5;
    rgb = lerp(L_out, rgb, sat * 2.0);
    rgb = min(rgb, L_ref); // hard ceiling at display peak

    return rgb;

#else
    // --------------------------------------------------------
    // Standard path (Soop sandwich, SDR, or gamma-encoded)
    // Hybrid: XYZ/Yxy chromaticity separation for perceptual accuracy,
    // but normalisation uses max channel instead of CIE Y.
    // This prevents blue-dominant scenes from being under-normalised
    // (CIE Y weights blue at only 7.2%, max channel is colour-agnostic).
    // Chromaticity (x,y) is still preserved from Yxy so hue is accurate.
    // --------------------------------------------------------
    float3 xyz = mul(k709_to_XYZ, c);
    float3 Yxy = XYZtoYxy(xyz);

    // Use max channel as luminance reference -- colour-agnostic,
    // correctly handles blue/cyan dominant content
    float ch_max  = max(max(c.r, c.g), c.b);
    float Y_lin   = max(ch_max, 0.0);
    float Y_peak  = max(Y_lin, 1.0);
    float Y_norm  = Y_lin / Y_peak;
    float Y_g     = pow(Y_norm, 1.0/2.4);

    float Y_b = (brightness >= 0.0)
        ? Bezier(Y_g, lerp(kMidBrightness, kTopBrightness, brightness))
        : Bezier(Y_g, lerp(kMidBrightness, kBotBrightness, -brightness));
    float Y_c = (contrast >= 0.0)
        ? Bezier(Y_b, lerp(kMidContrast, kTopContrast, contrast))
        : Bezier(Y_b, lerp(kMidContrast, kBotContrast, -contrast));

    float Y_out   = pow(max(Y_c, 0.0), 2.4) * Y_peak;

    // Scale input RGB by the ratio of new to old max channel
    // This applies the brightness/contrast curve while preserving
    // the exact chromaticity of the original colour
    float3 rgb = (Y_lin > 0.0001) ? c * (Y_out / Y_lin) : c;

// No gamut clipping needed -- scaling preserves exact input chromaticity
    // BCS_GAMUT_CLAMP=1 adds a hard safety clamp if needed for edge cases
#if BCS_GAMUT_CLAMP
    rgb = clamp(rgb, 0.0, 1.0);
#endif

    float  luma  = dot(max(rgb, 0.0), float3(0.2125, 0.7154, 0.0721));
    float  sat   = 0.5 + saturation * 0.5;
    rgb = lerp(luma, rgb, sat * 2.0);

    return rgb;
#endif
}

// ============================================================
// Gamma helpers
// ============================================================

float3 to_linear(float3 x)   { return x < 0.04045 ? x/12.92 : pow((x+0.055)/1.055, 2.4); }
float3 from_linear(float3 x) { return x < 0.0031308 ? 12.92*x : 1.055*pow(x,1.0/2.4)-0.055; }
float3 crt_to_linear(float3 x)   { return pow(max(x, 0.0), crt_gamma_in); }
float3 crt_from_linear(float3 x) { return pow(max(x, 0.0), 1.0/crt_gamma_out); }

// ============================================================
// Gaussian helper
// ============================================================

float gauss(float x, float sigma)
{
    return exp(-(x*x) / (2.0*sigma*sigma));
}

// ============================================================
// Geometry warp: pincushion UV distortion applied at source
// sampling to keep scanlines/mask geometrically straight.
// ============================================================

// Compute warped texcoord only -- no sampling
float2 geom_warp(float2 tc)
{
#if ENABLE_GEOMETRY
    if (crt_geom_mode == 0) return tc;

    float ar = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
    float2 uv = (tc * 2.0 - 1.0) / crt_geom_zoom;
    uv.x *= ar;

    float cv = crt_geom_curvature;

    if (crt_geom_mode == 1)
    {
        uv.x *= 1.0 + (uv.y * uv.y) / (cv * cv);
        uv.y *= 1.0 + (uv.x * uv.x) / (cv * cv * ar * ar);
    }
    else if (crt_geom_mode == 2)
    {
        uv.x *= 1.0 + pow(abs(uv.y) / cv, 1.5);
        uv.y *= 1.0 + pow(abs(uv.x) / (cv * ar), 1.5);
    }
    else
    {
        uv.x *= 1.0 + (uv.y * uv.y) / (cv * cv);
    }

    uv.x /= ar;
    return clamp(uv * 0.5 + 0.5, 0.0, 1.0);
#else
    return tc;
#endif
}

// ============================================================
// Lanczos2 kernel: 2-lobe sinc approximation
// Sharper reconstruction than bilinear -- significantly reduces
// the softening introduced by the geometry UV warp.
// 4x4 tap grid (16 samples) centred on the warped texcoord.
// ============================================================
// ── Reconstruction filter functions ─────────────────────────────
// Used by pre-blur and geometry warp sampling.
// Selected by PREBLUR_FILTER: 0=Lanczos2, 1=Lanczos3, 2=Catmull-Rom

// Lanczos: sinc(x)*sinc(x/a), a = lobe count (2 or 3)
float lanczos_weight(float x, float a)
{
    const float PI = 3.14159265358979;
    if (abs(x) < 0.0001) return 1.0;
    if (abs(x) >= a)     return 0.0;
    float px  = PI * x;
    float pxa = PI * x / a;
    return (sin(px) / px) * (sin(pxa) / pxa);
}

// Catmull-Rom: piecewise cubic spline, 4-tap support [-2,2]
// Slightly crisper than Lanczos2 on high-contrast edges with less ringing.
float catmull_rom_weight(float x)
{
    x = abs(x);
    if (x >= 2.0) return 0.0;
    if (x >= 1.0) return ((-0.5*x + 2.5)*x - 4.0)*x + 2.0;
    return ((1.5*x - 2.5)*x*x + 1.0);
}

// Legacy alias
float lanczos2_weight(float x) { return lanczos_weight(x, 2.0); }

// Unified reconstruction sampler -- switches on PREBLUR_FILTER
float recon_weight(float x)
{
#if PREBLUR_FILTER == 2
    return catmull_rom_weight(x);
#elif PREBLUR_FILTER == 1
    return lanczos_weight(x, 3.0);
#else
    return lanczos_weight(x, 2.0);
#endif
}

float3 geom_sample_lanczos2(sampler2D tex, float2 tc)
{
    float2 px      = ReShade::PixelSize;
    float2 tc_px   = tc / px;
    float2 tc_base = floor(tc_px);

    // Tap radius: 2 for Lanczos2/Catmull-Rom (4x4=16 taps),
    //             3 for Lanczos3 (6x6=36 taps)
#if PREBLUR_FILTER == 1
    const int r = 3;
#else
    const int r = 2;
#endif

    float3 result = 0.0;
    float  wsum   = 0.0;

    for (int j = -r + 1; j <= r; j++)
    {
        float wy = recon_weight(tc_px.y - (tc_base.y + float(j)));
        for (int i = -r + 1; i <= r; i++)
        {
            float wx = recon_weight(tc_px.x - (tc_base.x + float(i)));
            float  w = wx * wy;
            float2 sample_tc = (tc_base + float2(float(i), float(j))) * px;
            result += tex2D(tex, clamp(sample_tc, 0.0, 1.0)).rgb * w;
            wsum   += w;
        }
    }
    return result / max(wsum, 1e-5);
}

// ============================================================
// Aperture grille mask (resolution-aware, analytically AA'd)
// ============================================================

#define CRT_REFERENCE_WIDTH 3840.0

// ============================================================
// Multi-type CRT mask
// 0: Aperture Grille (horizontal RGB stripes)
// 1: Diagonal Aperture Grille (staggered rows, better for QD-OLED)
// 2: Slot Mask (aperture grille + alternating dark rows)
// 3: Trinitron (wider green, narrower R/B -- real Trinitron proportions)
// ============================================================

float3 crt_mask_apply(float2 fc, float tw_ref, float strength, float sharp,
                      float3 phcol, int mask_type, float slot_dark,
                      int offset_x, int offset_y, float2 fc_clean, float pixel_luma)
{
    float tw     = tw_ref * (float(BUFFER_WIDTH) / CRT_REFERENCE_WIDTH);
    // Use fc_clean (without burn-in step offsets) for fwidth to prevent
    // discontinuities from integer triad steps from widening the AA edge
    float fw     = fwidth(fc_clean.x / tw);
    float edge   = max(fw, 1.0 / max(sharp, 0.01));

    float3 mask  = 1.0;

    if (mask_type == 0)
    {
        // -- Aperture Grille: standard horizontal RGB stripes --
        float t = frac(fc.x / tw);
        float r = smoothstep(0.0,   edge, t) * smoothstep(0.333, 0.333-edge, t);
        float g = smoothstep(0.333, 0.333+edge, t) * smoothstep(0.667, 0.667-edge, t);
        float b = smoothstep(0.667, 0.667+edge, t) * smoothstep(1.0,   1.0-edge, t);
        mask = float3(r, g, b) * phcol;
    }
    else if (mask_type == 1)
    {
        // -- Diagonal Aperture Grille: rows offset by 1 triad/2 --
        // Each row is shifted by half a triad relative to its neighbour.
        // This distributes the phosphor structure diagonally, reducing
        // sensitivity to QD-OLED triangular subpixel alignment.
        float row_offset = floor(fc.y) * (tw * 0.5);
        float t = frac((fc.x + row_offset) / tw);
        float r = smoothstep(0.0,   edge, t) * smoothstep(0.333, 0.333-edge, t);
        float g = smoothstep(0.333, 0.333+edge, t) * smoothstep(0.667, 0.667-edge, t);
        float b = smoothstep(0.667, 0.667+edge, t) * smoothstep(1.0,   1.0-edge, t);
        mask = float3(r, g, b) * phcol;
    }
    else if (mask_type == 2)
    {
        // -- Slot Mask: aperture grille + alternating dark rows --
        // Mimics shadow mask CRTs where horizontal slots separate scanlines.
        float t = frac(fc.x / tw);
        float r = smoothstep(0.0,   edge, t) * smoothstep(0.333, 0.333-edge, t);
        float g = smoothstep(0.333, 0.333+edge, t) * smoothstep(0.667, 0.667-edge, t);
        float b = smoothstep(0.667, 0.667+edge, t) * smoothstep(1.0,   1.0-edge, t);
        mask = float3(r, g, b) * phcol;
        // Slot rows: fwidth-based AA on the vertical row boundary.
        // Smoothstep replaces the hard binary step for anti-aliased slot edges.
        float  fw_y    = fwidth(fc.y * 0.5);
        float  row_t   = frac(floor(fc.y * 0.5) * 0.5); // 0 or 0.5
        float  slot_aa = smoothstep(0.0, fw_y, row_t) * smoothstep(0.5, 0.5 - fw_y, row_t);
        float  lane    = 1.0 - slot_dark * (1.0 - slot_aa);
        mask *= lane;
    }
    else if (mask_type == 3)
    {
        // -- Trinitron: wider green, narrower R/B --
        // Real Sony Trinitron tubes had green phosphors ~40% wider than R/B.
        // Proportions: R=0-0.25, G=0.25-0.75, B=0.75-1.0 (green gets 50% of triad)
        float t    = frac(fc.x / tw);
        float fedge = edge * 0.7; // sharper edges for Trinitron-style
        float r = smoothstep(0.0,  fedge, t) * smoothstep(0.25, 0.25-fedge, t);
        float g = smoothstep(0.25, 0.25+fedge, t) * smoothstep(0.75, 0.75-fedge, t);
        float b = smoothstep(0.75, 0.75+fedge, t) * smoothstep(1.0,  1.0-fedge,  t);
        mask = float3(r, g, b) * phcol;
    }
    else if (mask_type == 4)
    {
        // -- QD-OLED Delta: scaled checkerboard based on physical A95L subpixel layout --
        // triad_width=2.0 = 1:1 physical pixel mapping (native subpixel size)
        // triad_width=4.0 = each virtual phosphor covers 2 physical pixels (coarser, more visible)
        // triad_width=6.0 = 3 physical pixels per phosphor, very visible structure
        // The 2x2 checkerboard tile scales with tw so triad width is meaningful.
        // Tile pattern:
        //   [G][R]   (even virtual row)
        //   [B][G]   (odd virtual row)

        // Scale fc by tw/2 so the 2x2 tile covers tw pixels
        // At tw=2: 1 pixel per cell. At tw=4: 2 pixels per cell.
        float  cell_size = tw * 0.5; // pixels per subpixel cell
        float2 fc_off    = float2(floor(abs(fc))) + float2(float(crt_mask_offset_x),
                                                            float(crt_mask_offset_y));

        // Determine which 2x2 virtual tile position we're in using uint arithmetic
        // Converting to uint before modulo guarantees exact 0/1 with no float error
        // at any resolution or cell size
        // Small epsilon prevents boundary rounding errors at non-integer cell sizes
        // (e.g. triad 4.0 at 4K with DSR where fc coordinates may fall just below
        // an integer boundary due to floating point precision)
        uint2 tile_idx = uint2(floor(fc_off / cell_size + 0.001));
        float cx       = float(tile_idx.x & 1u); // exactly 0 or 1
        float cy       = float(tile_idx.y & 1u);

        // Subpixel identity:
        // (cx=0, cy=0)=Green  (cx=1, cy=0)=Red
        // (cx=0, cy=1)=Blue   (cx=1, cy=1)=Green
        float is_green = (1.0 - cx) * (1.0 - cy) + cx * cy;
        float is_red   = cx * (1.0 - cy);
        float is_blue  = (1.0 - cx) * cy;

        // Position within the current cell, -1..1
        // Used for the rounded square phosphor shape
        float2 cell_pos = (frac(fc_off / cell_size) * 2.0 - 1.0);

        // Phosphor sizes scale with cell_size to maintain consistent fill ratio
        float fill_scale = 1.0 - 0.08 / max(cell_size, 0.5);

        // Green phosphor: larger rounded square (~60% of cell at native size)
        float g_size   = 0.72 + (0.88 - 0.72) * saturate((cell_size - 1.0) / 3.0);
        g_size        *= fill_scale;
        float g_soft   = max(sharp * 0.1, 0.15) / max(cell_size * 0.5, 1.0);
        float g_shape  = smoothstep(g_size, g_size - g_soft,
                         max(abs(cell_pos.x), abs(cell_pos.y)));

        // Red/Blue phosphors: smaller rounded square (~40% of cell at native size)
        float rb_size  = 0.52 + (0.76 - 0.52) * saturate((cell_size - 1.0) / 3.0);
        rb_size       *= fill_scale;
        float rb_soft  = max(sharp * 0.1, 0.15) / max(cell_size * 0.5, 1.0);
        float rb_shape = smoothstep(rb_size, rb_size - rb_soft,
                         max(abs(cell_pos.x), abs(cell_pos.y)));

        mask = float3(is_red * rb_shape,
                      is_green * g_shape,
                      is_blue * rb_shape) * phcol;
    }
    else if (mask_type == 5)
    {
        // -- QD-OLED Luminance Gate: mask strength inversely proportional to pixel luminance --
        // The QD-OLED colour pattern is applied at full strength in dark areas and
        // reduced toward passthrough in bright areas. Bright pixels (highlights) are
        // barely affected; dark pixels and midtones get the full phosphor texture.
        // No global darkening because bright areas compensate -- they pass through cleanly.
        // This matches real CRT physics: phosphor gaps are only visible in darker areas
        // because bright phosphors bleed light that fills adjacent gaps.

        float  cell_size = max(tw * 0.5, 0.5);
        float2 fc_off    = float2(floor(abs(fc))) +
                           float2(float(crt_mask_offset_x), float(crt_mask_offset_y));

        // Compute QD-OLED subpixel identity and shape (same as type 4)
        uint2 tile_idx = uint2(floor(fc_off / cell_size + 0.001));
        float cx       = float(tile_idx.x & 1u);
        float cy       = float(tile_idx.y & 1u);

        float is_green = (1.0 - cx) * (1.0 - cy) + cx * cy;
        float is_red   = cx * (1.0 - cy);
        float is_blue  = (1.0 - cx) * cy;

        float2 cell_pos = (frac(fc_off / cell_size) * 2.0 - 1.0);

        float fill_scale = 1.0 - 0.08 / max(cell_size, 0.5);

        float g_size   = 0.72 + (0.88 - 0.72) * saturate((cell_size - 1.0) / 3.0);
        g_size        *= fill_scale;
        float g_soft   = max(sharp * 0.1, 0.15) / max(cell_size * 0.5, 1.0);
        float g_shape  = smoothstep(g_size, g_size - g_soft,
                         max(abs(cell_pos.x), abs(cell_pos.y)));

        float rb_size  = 0.52 + (0.76 - 0.52) * saturate((cell_size - 1.0) / 3.0);
        rb_size       *= fill_scale;
        float rb_soft  = max(sharp * 0.1, 0.15) / max(cell_size * 0.5, 1.0);
        float rb_shape = smoothstep(rb_size, rb_size - rb_soft,
                         max(abs(cell_pos.x), abs(cell_pos.y)));

        float3 qdoled_mask = float3(is_red * rb_shape,
                                    is_green * g_shape,
                                    is_blue * rb_shape) * phcol;

        // Luminance gate: use actual image pixel luminance to scale mask application.
        // High luma -> gate near 0 -> mask approaches 1.0 (bright pixels pass through clean)
        // Low luma  -> gate near 1 -> mask applies fully (dark areas get phosphor texture)
        // Power curve 0.5 means midtones get ~70% of full mask strength.
        // Gate: remap pixel_luma against threshold then apply curve
        float gate_input = saturate((pixel_luma - crt_luma_gate_threshold) /
                           max(1.0 - crt_luma_gate_threshold, 0.001));
        float gate = 1.0 - pow(gate_input, crt_luma_gate_curve);
        mask = lerp(1.0, qdoled_mask, gate);
    }

    return saturate(lerp(1.0, mask, strength));
}

// Legacy name kept for any internal references
float3 aperture_grille(float2 fc, float tw_ref, float strength, float sharp, float3 phcol)
{
    return crt_mask_apply(fc, tw_ref, strength, sharp, phcol, 0, 0.5, 0, 0, fc, 0.5);
}

// ============================================================
// Megatron Bezier scanline beam
// ============================================================

float megatron_scanline(float ch, float beam_dist, float scan_min, float scan_max, float attack)
{
    float dist = clamp(beam_dist / ((ch*(scan_max-scan_min)) + scan_min), 0.0, 1.0);
    return Bezier(dist, float4(1.0, 1.0, ch*attack, 0.0));
}

// ============================================================
// Glow helpers
// ============================================================

float3 balance_glow(float3 g, float balance)
{
    float luma = dot(g, float3(0.2126, 0.7152, 0.0722));
    float peak = max(max(g.r, g.g), g.b);
    float3 norm = (peak > 0.0001) ? (g*(luma/peak)) : g;
    return lerp(norm, g, balance);
}

// ============================================================
// Grain helpers (Marty METEOR inlined)
// ============================================================

uint grain_uhash(uint x) { x^=x>>16; x*=0x21f0aaad; x^=x>>15; x*=0xd35a2d97; x^=x>>16; return x; }
float  grain_unorm1(uint u) { return asfloat((u>>9u)|0x3F800000u)-1.0; }
float2 grain_unorm2(uint u) { return asfloat((uint2(u<<7u,u>>9u)&0x7FFF80u)|0x3F800000u)-1.0; }
float  grain_next1(inout uint r) { r=grain_uhash(r); return grain_unorm1(r); }
float2 grain_next2(inout uint r) { r=grain_uhash(r); return grain_unorm2(r); }
float3 grain_bm3(float3 u) { float2 d; sincos(u.x*6.2831853,d.y,d.x); d*=sqrt(-2.0*log(u.z)); return float3(d.x,d.y,d.x*d.y); }
float2 grain_boxmuller_2d(float2 u) { float2 d; sincos(u.x*6.2831853,d.y,d.x); d*=sqrt(-2.0*log(max(1.0-u.y,1e-6))); return d; }
#define GWP 15.0
float3 grain_hdr(float3 c) { float w=1+rcp(1e-6+GWP); return c/(w-c); }
float3 grain_sdr(float3 c) { float w=1+rcp(1e-6+GWP); return w*c*rcp(1+c); }
#define glin(x)  ((x)*0.283799*((2.52405+(x))*(x)))
#define genc(x)  (1.14374*(-0.126893*(x)+sqrt((x))))

// Analytical Poisson variance for film grain.
// Models highlight rolloff: grain peaks at midtones (luma=0.5) and rolls
// off in both shadows and highlights -- luma*(1-luma) peaks at 0.25 when luma=0.5.
// Scaled to match the original amplitude: at luma=0.5, output = intensity^2 * 0.35.
// poisson_shape(0.5) = 0.5*0.5 = 0.25, so scale = 0.35/0.25 = 1.4
float grain_poisson_sigma(float luma, float intensity)
{
    // poisson_shape peaks at 0.25 (luma=0.5). Scale by 4.0 so the midtone
    // amplitude exactly matches the original intensity^2 * 0.35 formula.
    float poisson_shape = luma * (1.0 - luma);
    return (intensity * intensity * 0.35) * (poisson_shape * 4.0);
}

// ============================================================
// Pass 1: Pre-blur horizontal
// Samples clean backbuffer, blurs horizontally.
// Equivalent to Guest Advanced SIZEH/SIGMA_H gaussian pass.
// ============================================================

#if ENABLE_PREBLUR
void crt_preblur_h_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float2 texcoord_w = geom_warp(texcoord);

    if (crt_preblur_h_sigma < 0.001)
    {
        color = float4(geom_sample_lanczos2(ReShade::BackBuffer, texcoord_w), 1.0);
        return;
    }

    float3 result = 0.0;
    float  wsum   = 0.0;
    float  px     = ReShade::PixelSize.x;
    int    radius = int(crt_preblur_h_radius);

    for (int i = -radius; i <= radius; i++)
    {
        // Use Lanczos2 only at centre (i==0) -- offset taps use bilinear since
        // the warp gradient is small across one pixel at preblur scale
        float3 s = (i == 0)
            ? geom_sample_lanczos2(ReShade::BackBuffer, texcoord_w)
            : tex2D(ReShade::BackBuffer, texcoord_w + float2(float(i)*px, 0.0)).rgb;
        float  w = gauss(float(i), crt_preblur_h_sigma);
        result  += s * w;
        wsum    += w;
    }

    color = float4(result / max(wsum, 1e-5), 1.0);
}
#endif

// ============================================================
// Pass 2: Pre-blur vertical
// Samples H-blurred texture, blurs vertically.
// Equivalent to Guest Advanced SIZEV/SIGMA_V gaussian pass.
// ============================================================

#if ENABLE_PREBLUR
void crt_preblur_v_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    if (crt_preblur_v_sigma < 0.001)
    {
        color = tex2D(crt_preblur_h_sampler, texcoord);
        return;
    }

    float3 result = 0.0;
    float  wsum   = 0.0;
    float  py     = ReShade::PixelSize.y * float(PREBLUR_RESOLUTION);
    int    radius = int(crt_preblur_v_radius);

    for (int j = -radius; j <= radius; j++)
    {
        float3 s = tex2D(crt_preblur_h_sampler, texcoord + float2(0.0, float(j)*py)).rgb;
        float  w = gauss(float(j), crt_preblur_v_sigma);
        result  += s * w;
        wsum    += w;
    }

    color = float4(result / max(wsum, 1e-5), 1.0);
}
#endif

// ============================================================
// Pass 3: Halation (bright-only blur at quarter resolution)
// Only bright elements scatter -- no global haze.
// Bilinear sampling of the quarter-res texture in main pass
// gives free additional smoothing.
// ============================================================

#if ENABLE_HALATION
void crt_halation_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 result = 0.0;
    float  wsum   = 0.0;
    // Pixel size scaled by resolution divisor
    float  px     = ReShade::PixelSize.x * float(HALATION_RESOLUTION);
    int    radius = int(crt_halation_radius);

    for (int i = -radius; i <= radius; i++)
    {
        #if ENABLE_PREBLUR
        float3 s = tex2D(crt_preblur_v_sampler, texcoord + float2(float(i)*px, 0.0)).rgb;
        #elif ENABLE_GEOMETRY
        float  px_bb = ReShade::PixelSize.x;
        float2 uv_hal = geom_warp(texcoord) + float2(float(i)*px_bb, 0.0);
        float3 s = tex2D(ReShade::BackBuffer, uv_hal).rgb;
        #else
        float  px_bb = ReShade::PixelSize.x;
        float2 uv_hal = texcoord + float2(float(i)*px_bb, 0.0);
        float3 s = tex2D(ReShade::BackBuffer, uv_hal).rgb;
        #endif

        float luma  = dot(s, float3(0.2126, 0.7152, 0.0722));
        float above = max(luma - crt_halation_threshold, 0.0);
        // Warm target: lerp between neutral white and warm orange-red.
        // crt_halation_warmth=0 -> (1,1,1)*luma (neutral white desaturation)
        // crt_halation_warmth=1 -> (1.08,0.95,0.82)*luma (warm CRT phosphor tint)
        float3 warm_tint = lerp(float3(1.0, 1.0, 1.0),
                                float3(1.08, 0.95, 0.82),
                                crt_halation_warmth) * luma;
        s = lerp(s, warm_tint, crt_halation_saturation) * (above / max(luma, 0.0001));

        // sigma_h = sigma * anisotropy -- wider H spread when anisotropy > 1
        float w = gauss(float(i), crt_halation_sigma * max(crt_halation_anisotropy, 0.01));
        result += s * w;
        wsum   += w;
    }

    color = float4(result / max(wsum, 1e-5), 1.0);
}


// Vertical halation pass: blurs the horizontal result vertically.
// sigma_v = sigma / anisotropy -- narrower when anisotropy > 1 (wider H than V).
void crt_halation_v_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 result = 0.0;
    float  wsum   = 0.0;
    float  py     = ReShade::PixelSize.y * float(HALATION_RESOLUTION);
    int    radius = int(crt_halation_radius);
    float  sigma_v = crt_halation_sigma / max(crt_halation_anisotropy, 0.01);

    for (int j = -radius; j <= radius; j++)
    {
        float3 s = tex2D(crt_halation_sampler, texcoord + float2(0.0, float(j)*py)).rgb;
        float w = gauss(float(j), sigma_v);
        result += s * w;
        wsum   += w;
    }
    color = float4(result / max(wsum, 1e-5), 1.0);
}
#endif

// ============================================================
// Pass 4: Glow horizontal blur
// Samples pre-blurred signal for luminance-weighted glow.
// ============================================================

void crt_glow_h_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float  px     = ReShade::PixelSize.x * float(PREBLUR_RESOLUTION);
    int    radius = min(int(crt_glow_h_radius), GLOW_H_MAX_RADIUS);
    float  sigma_base = crt_glow_sigma * crt_glow_h_radius * 0.25;

    // Spectral bloom: per-channel sigma based on wavelength-dependent diffraction.
    // Red (~700nm) spreads least, blue (~450nm) spreads most.
    // At spectral=0: all channels identical. At spectral=1: R=0.75x, G=1.0x, B=1.35x.
    float3 sigma_rgb = sigma_base * lerp(float3(1.0, 1.0, 1.0),
                                         float3(0.75, 1.0, 1.35),
                                         crt_glow_spectral);

    float3 result  = 0.0;
    float3 wsum_rgb = 0.0;

    [unroll]
    for (int i = -GLOW_H_MAX_RADIUS; i <= GLOW_H_MAX_RADIUS; i++)
    {
        // Per-channel Gaussian weight -- zero for taps outside radius
        float3 w = (abs(i) <= radius)
                 ? float3(gauss(float(i), sigma_rgb.r),
                          gauss(float(i), sigma_rgb.g),
                          gauss(float(i), sigma_rgb.b))
                 : float3(0.0, 0.0, 0.0);

        #if ENABLE_PREBLUR
        float3 s = tex2D(crt_preblur_v_sampler, texcoord + float2(float(i)*px, 0.0)).rgb;
        #elif ENABLE_GEOMETRY
        float2 uv_glow = geom_warp(texcoord) + float2(float(i)*px, 0.0);
        float3 s = tex2D(ReShade::BackBuffer, uv_glow).rgb;
        #else
        float2 uv_glow = texcoord + float2(float(i)*px, 0.0);
        float3 s = tex2D(ReShade::BackBuffer, uv_glow).rgb;
        #endif
        float lum = dot(s, float3(0.2126, 0.7152, 0.0722));
        float gate;
        if (crt_glow_knee < 0.001)
            gate = float(lum > crt_glow_threshold);
        else
            { float t = saturate((lum - crt_glow_threshold) / crt_glow_knee);
              gate = t * t * (3.0 - 2.0 * t); }
        s = max(s - crt_glow_threshold, 0.0) * lum * gate;

        result   += s * w;
        wsum_rgb += w;
    }

    float3 g = result / max(wsum_rgb, 1e-5);
    g = balance_glow(g, crt_glow_balance);
    color = float4(g, 1.0);
}

// ============================================================
// GlowV pass: vertical glow blur + combine with H glow
// Separated from MainCRT to allow independent GPU scheduling
// and to apply GLOW_V_MAX_RADIUS compile-time unroll.
// ============================================================

void crt_glow_v_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 h_glow = tex2D(crt_glow_sampler, texcoord).rgb;

    if (crt_glow_strength < 0.001)
    {
        color = float4(h_glow, 1.0);
        return;
    }

    float3 v_glow = 0.0;
    float  vwsum  = 0.0;
    float  py     = ReShade::PixelSize.y * float(PREBLUR_RESOLUTION);
    int    vrad   = min(int(crt_glow_v_radius), GLOW_V_MAX_RADIUS);
    float  vsigma = crt_glow_sigma * crt_glow_v_radius * 0.5;

    [unroll]
    for (int j = -GLOW_V_MAX_RADIUS; j <= GLOW_V_MAX_RADIUS; j++)
    {
        float w = (abs(j) <= vrad) ? gauss(float(j), vsigma) : 0.0;
        #if ENABLE_PREBLUR
        float3 s = tex2D(crt_preblur_v_sampler, texcoord + float2(0.0, float(j)*py)).rgb;
        #elif ENABLE_GEOMETRY
        float  py_bb = ReShade::PixelSize.y;
        float3 s = tex2D(ReShade::BackBuffer, geom_warp(texcoord) + float2(0.0, float(j)*py_bb)).rgb;
        #else
        float  py_bb = ReShade::PixelSize.y;
        float3 s = tex2D(ReShade::BackBuffer, texcoord + float2(0.0, float(j)*py_bb)).rgb;
        #endif
        float lum = dot(s, float3(0.2126, 0.7152, 0.0722));
        float gate_v;
        if (crt_glow_knee < 0.001)
            gate_v = float(lum > crt_glow_threshold);
        else
            { float t = saturate((lum - crt_glow_threshold) / crt_glow_knee);
              gate_v = t * t * (3.0 - 2.0 * t); }
        s = max(s - crt_glow_threshold, 0.0) * lum * gate_v;
        v_glow += s * w;
        vwsum  += w;
    }
    v_glow /= max(vwsum, 1e-5);
    v_glow = balance_glow(v_glow, crt_glow_balance);

    float3 glow = lerp(v_glow, h_glow, crt_glow_h_mix);
    color = float4(glow, 1.0);
}

// ============================================================
// Wide glow H pass: large-area bloom at quarter resolution
// ============================================================

void crt_glow_wide_h_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    if (crt_glow_wide_strength < 0.001) { color = float4(0.0, 0.0, 0.0, 1.0); return; }

    float  px     = ReShade::PixelSize.x * float(GLOW_RESOLUTION * 2);
    int    radius = min(int(crt_glow_wide_radius), GLOW_H_MAX_RADIUS);
    float  sigma  = crt_glow_sigma * crt_glow_wide_radius * 0.5;
    float3 result = 0.0;
    float  wsum   = 0.0;

    [unroll]
    for (int i = -GLOW_H_MAX_RADIUS; i <= GLOW_H_MAX_RADIUS; i++)
    {
        float w = (abs(i) <= radius) ? gauss(float(i), sigma) : 0.0;
        #if ENABLE_PREBLUR
        float3 s = tex2D(crt_preblur_v_sampler, texcoord + float2(float(i)*px, 0.0)).rgb;
        #else
        float3 s = tex2D(ReShade::BackBuffer, texcoord + float2(float(i)*px, 0.0)).rgb;
        #endif
        float lum = dot(s, float3(0.2126, 0.7152, 0.0722));
        float gate = float(lum > crt_glow_wide_threshold);
        s = max(s - crt_glow_wide_threshold, 0.0) * lum * gate;
        result += s * w;
        wsum   += w;
    }
    color = float4(result / max(wsum, 1e-5), 1.0);
}

// Wide glow V pass: vertical blur + combine
void crt_glow_wide_v_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    if (crt_glow_wide_strength < 0.001) { color = float4(0.0, 0.0, 0.0, 1.0); return; }

    float  py     = ReShade::PixelSize.y * float(GLOW_RESOLUTION * 2);
    int    vrad   = min(int(crt_glow_wide_radius), GLOW_V_MAX_RADIUS);
    float  vsigma = crt_glow_sigma * crt_glow_wide_radius * 0.5;
    float3 result = 0.0;
    float  wsum   = 0.0;

    [unroll]
    for (int j = -GLOW_V_MAX_RADIUS; j <= GLOW_V_MAX_RADIUS; j++)
    {
        float w = (abs(j) <= vrad) ? gauss(float(j), vsigma) : 0.0;
        #if ENABLE_PREBLUR
        float3 s = tex2D(crt_preblur_v_sampler, texcoord + float2(0.0, float(j)*py)).rgb;
        #else
        float3 s = tex2D(ReShade::BackBuffer, texcoord + float2(0.0, float(j)*py)).rgb;
        #endif
        float lum = dot(s, float3(0.2126, 0.7152, 0.0722));
        float gate = float(lum > crt_glow_wide_threshold);
        s = max(s - crt_glow_wide_threshold, 0.0) * lum * gate;
        result += s * w;
        wsum   += w;
    }

    // Sample wide H glow and combine
    float3 wide_h = tex2D(crt_glow_wide_sampler, texcoord).rgb;
    float3 wide_v = result / max(wsum, 1e-5);
    float3 wide   = lerp(wide_v, wide_h, crt_glow_h_mix);
    wide = balance_glow(wide, crt_glow_balance);
    color = float4(wide, 1.0);
}

// ============================================================
// Pass 5: Main CRT pass
// Uses pre-blurred signal as source instead of raw backbuffer.
// ============================================================

void crt_main_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float2 fc = texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT);

    // -- Anti burn-in offsets --
    // IMPORTANT: All offsets applied only to mask and scanline pattern coordinates,
    // never to the image sampling UVs. Sub-pixel shifts on scanlines cause
    // brightness fluctuation because frac() is non-linear across the beam profile.
    // Scanlines use integer steps only. Mask uses continuous sinusoidal shift.

    // Anti burn-in: integer triad-width steps only.
    // Shifting by exact multiples of the triad width is visually identical
    // (the pattern is periodic) but different display pixels receive each phosphor,
    // distributing wear. No brightness fluctuation possible at any mask strength.

    #if ENABLE_BURNIN_PHASE
        // Phase: alternates between 0 and 0.5 triad widths on a slow timer.
        // 0.5 triad = each phosphor swaps to its neighbour's position.
        float phase_ms      = crt_burnin_phase_period * 60000.0;
        float phase_steps_  = floor(crt_timer / phase_ms);
        float phase_toggle  = phase_steps_ - floor(phase_steps_ * 0.5) * 2.0; // 0 or 1
        float tw_px_phase   = crt_triad_width * (float(BUFFER_WIDTH) / 3840.0);
        float phase_h       = phase_toggle * tw_px_phase * 0.5;
    #else
        float phase_h       = 0.0;
    #endif

    #if ENABLE_BURNIN_ORBIT
        // Orbit: steps through 0, 1, 2, 3 quarter-triad positions on a slow timer.
        // Full triad = 4 steps, each step = 0.25 triad width.
        float orbit_ms      = crt_burnin_orbit_period * 60000.0;
        float orbit_steps_  = floor(crt_timer / orbit_ms);
        float orbit_phase   = orbit_steps_ - floor(orbit_steps_ * 0.25) * 4.0; // 0,1,2,3
        float tw_px_orbit   = crt_triad_width * (float(BUFFER_WIDTH) / 3840.0);
        float orbit_h       = orbit_phase * tw_px_orbit * 0.25;
    #else
        float orbit_h       = 0.0;
    #endif



    // Chromatic aberration + convergence UV offsets.
    // When disabled, all channels sample from the same texcoord.
    #if ENABLE_CA
    float2 ca_centre  = texcoord - 0.5;
    float  ca_dist    = pow(length(ca_centre * float2(float(BUFFER_WIDTH)/float(BUFFER_HEIGHT), 1.0)),
                            crt_ca_falloff);
    float2 ca_vec     = ca_centre * ca_dist * crt_ca_strength;
    float2 ca_r = -ca_vec * 0.5;
    float2 ca_b =  ca_vec;
    #else
    float2 ca_r = 0.0;
    float2 ca_b = 0.0;
    #endif

    #if ENABLE_CONVERGENCE
    // Radial misconvergence: Δy = k * x² where x is normalised screen position.
    // Grows from zero at centre to maximum at horizontal edges.
    // Red diverges upward, blue downward -- matches real pincushion misconvergence.
    float  cx          = (texcoord.x - 0.5) * 2.0;
    float  ar          = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
    float  radial_err  = crt_convergence_radial * cx * cx * ar * ReShade::PixelSize.y;
    // Horizontal convergence: independent per-channel X offset
    float2 h_r = float2(crt_convergence_h_r * ReShade::PixelSize.x, 0.0);
    float2 h_b = float2(crt_convergence_h_b * ReShade::PixelSize.x, 0.0);
    float2 uv_r = texcoord + float2(0.0, (crt_convergence_r - radial_err) * ReShade::PixelSize.y) + ca_r + h_r;
    float2 uv_g = texcoord + float2(0.0,  crt_convergence_g               * ReShade::PixelSize.y);
    float2 uv_b = texcoord + float2(0.0, (crt_convergence_b + radial_err) * ReShade::PixelSize.y) + ca_b + h_b;
    #else
    float2 uv_r = texcoord + ca_r;
    float2 uv_g = texcoord;
    float2 uv_b = texcoord + ca_b;
    #endif

    float3 c;
    #if ENABLE_PREBLUR
    c = float3(
        tex2D(crt_preblur_v_sampler, uv_r).r,
        tex2D(crt_preblur_v_sampler, uv_g).g,
        tex2D(crt_preblur_v_sampler, uv_b).b);

    // -- Vertical per-channel spread (ENABLE_PREBLUR + ENABLE_CONVERGENCE path) --
    #if ENABLE_CONVERGENCE
    if (crt_convergence_v_spread > 0.001)
    {
        float py = ReShade::PixelSize.y * crt_convergence_v_spread;
        float r_above = tex2D(crt_preblur_v_sampler, float2(uv_r.x, uv_r.y - py*0.5)).r;
        float r_below = tex2D(crt_preblur_v_sampler, float2(uv_r.x, uv_r.y + py*0.5)).r;
        float b_above = tex2D(crt_preblur_v_sampler, float2(uv_b.x, uv_b.y - py*0.3)).b;
        float b_below = tex2D(crt_preblur_v_sampler, float2(uv_b.x, uv_b.y + py*0.3)).b;
        c.r = (c.r + r_above + r_below) / 3.0;
        c.b = (c.b + b_above + b_below) / 3.0;
    }
    #endif // ENABLE_CONVERGENCE
    #elif ENABLE_GEOMETRY
    {
        // Geometry: one Lanczos reconstruction at warped centre position,
        // then cheap bilinear reads for CA/convergence channel offsets.
        // This avoids 3x Lanczos cost -- the CA/convergence offsets are
        // sub-pixel and bilinear is sufficient for them.
        float2 tc_w = geom_warp(texcoord);
        float3 c_warp = geom_sample_lanczos2(ReShade::BackBuffer, tc_w);
        // For CA/convergence: read neighbours bilinearly and extract channels
        c = c_warp; // start with Lanczos centre
        #if ENABLE_CA || ENABLE_CONVERGENCE
        float  py_off = ReShade::PixelSize.y;
        float2 wuv_r  = tc_w + ca_r + float2(0.0,
            #if ENABLE_CONVERGENCE
            (crt_convergence_r - radial_err) * py_off
            #else
            0.0
            #endif
            );
        float2 wuv_b  = tc_w + ca_b + float2(0.0,
            #if ENABLE_CONVERGENCE
            (crt_convergence_b + radial_err) * py_off
            #else
            0.0
            #endif
            );
        c.r = tex2D(ReShade::BackBuffer, wuv_r).r;
        c.b = tex2D(ReShade::BackBuffer, wuv_b).b;
        #endif
    }
    #else
    // No geometry, no preblur: plain bilinear -- fast path
    c = float3(
        tex2D(ReShade::BackBuffer, uv_r).r,
        tex2D(ReShade::BackBuffer, uv_g).g,
        tex2D(ReShade::BackBuffer, uv_b).b);
    #endif

    // -- Composite video: chroma blur + luma sharpen on correct source --
    // Runs after source sampling so it operates on the actual current frame
    // with correct UV mapping (preblur/geometry/plain as appropriate).
    #if ENABLE_COMPOSITE
    if (crt_composite_chroma_blur > 0.001 || crt_composite_luma_sharpen > 0.001)
    {
        float luma = dot(c, float3(0.299, 0.587, 0.114));
        float px_c = ReShade::PixelSize.x;

        if (crt_composite_chroma_blur > 0.001)
        {
            int    taps      = int(ceil(crt_composite_chroma_blur * 2.0));
            float3 chroma_sum = 0.0;
            for (int ci = -taps; ci <= taps; ci++)
            {
                float  offs = (float(ci) + crt_composite_chroma_phase) * px_c;
                #if ENABLE_PREBLUR
                chroma_sum += float3(
                    tex2D(crt_preblur_v_sampler, uv_r + float2(offs, 0.0)).r,
                    tex2D(crt_preblur_v_sampler, uv_g + float2(offs, 0.0)).g,
                    tex2D(crt_preblur_v_sampler, uv_b + float2(offs, 0.0)).b);
                #else
                chroma_sum += float3(
                    tex2D(ReShade::BackBuffer, uv_r + float2(offs, 0.0)).r,
                    tex2D(ReShade::BackBuffer, uv_g + float2(offs, 0.0)).g,
                    tex2D(ReShade::BackBuffer, uv_b + float2(offs, 0.0)).b);
                #endif
            }
            float3 c_blurred    = chroma_sum / float(2*taps + 1);
            float  luma_blurred = dot(c_blurred, float3(0.299, 0.587, 0.114));
            float  luma_ratio   = (luma_blurred > 0.0001) ? luma / luma_blurred : 1.0;
            c = c_blurred * luma_ratio;
        }

        if (crt_composite_luma_sharpen > 0.001)
        {
            #if ENABLE_PREBLUR
            float3 left  = tex2D(crt_preblur_v_sampler, uv_g - float2(px_c * 2.0, 0.0));
            float3 right = tex2D(crt_preblur_v_sampler, uv_g + float2(px_c * 2.0, 0.0));
            #else
            float3 left  = tex2D(ReShade::BackBuffer, uv_g - float2(px_c * 2.0, 0.0));
            float3 right = tex2D(ReShade::BackBuffer, uv_g + float2(px_c * 2.0, 0.0));
            #endif
            float luma_l    = dot(left,  float3(0.299, 0.587, 0.114));
            float luma_r    = dot(right, float3(0.299, 0.587, 0.114));
            float edge      = luma - 0.5*(luma_l + luma_r);
            float luma_sharp = max(luma + edge * crt_composite_luma_sharpen, 0.0001);
            c *= luma_sharp / max(luma, 0.0001);
            c  = max(c, 0.0);
        }
    }
    #endif // ENABLE_COMPOSITE

    // -- Phosphor profile correction (before BCS) --
    #if ENABLE_PHOSPHOR
    if (crt_phosphor_strength > 0.001)
        c = apply_phosphor(c);

    // -- White point: chromatic adaptation D65 toward D55 (warm) or D93 (cool) --
    if (abs(crt_white_point) > 0.001)
    {
        float3 c_lin = pow(max(c, 0.0), 2.2);
        float m = abs(crt_white_point);
        float3 xyz;
        if (crt_white_point < 0.0)
            xyz = mul(c_lin, kD65_to_D55);
        else
            xyz = mul(c_lin, kD65_to_D93);
        // Back to sRGB via standard XYZ->sRGB
        float3 adapted = mul(xyz, kXYZ_to_sRGB);
        adapted = pow(max(adapted, 0.0), 1.0/2.2);
        c = lerp(c, adapted, m);
    }

    // -- Colour temperature (simple warm/cool shift in Gamma & Contrast) --
    if (abs(crt_colour_temp) > 0.001)
        c = apply_colour_temp(c, crt_colour_temp);
    #endif

    // -- Pre-emphasis / bandwidth limiting --
    // Applied to source signal before any CRT processing, matching the
    // signal chain position of real broadcast pre/de-emphasis.
    #if ENABLE_EDGE_FEEDBACK
    if (crt_edge_feedback_luma > 0.001 || crt_edge_feedback_chroma > 0.001)
    {
        // Cross-frame edge feedback: compare current pixel against previous
        // frame neighbours. Difference captures accumulated CRT processing
        // (mask, scanlines, vignette, warp) and feeds it back as enhancement.
        float2 px    = ReShade::PixelSize;
        float3 left  = tex2D(ReShade::BackBuffer, float2(texcoord.x - px.x, texcoord.y)).rgb;
        float3 right = tex2D(ReShade::BackBuffer, float2(texcoord.x + px.x, texcoord.y)).rgb;
        if (crt_edge_feedback_luma > 0.001)
        {
            float luma_c = dot(c,     float3(0.299, 0.587, 0.114));
            float luma_l = dot(left,  float3(0.299, 0.587, 0.114));
            float luma_r = dot(right, float3(0.299, 0.587, 0.114));
            float edge   = luma_c - 0.5*(luma_l + luma_r);
            c += edge * crt_edge_feedback_luma;
        }
        if (crt_edge_feedback_chroma > 0.001)
        {
            float luma         = dot(c, float3(0.299, 0.587, 0.114));
            float3 chroma_blur = (left + c + right) / 3.0;
            float luma_blur    = dot(chroma_blur, float3(0.299, 0.587, 0.114));
            c = chroma_blur + (luma - luma_blur);
            c = lerp(c, chroma_blur, crt_edge_feedback_chroma);
        }
        c = max(c, 0.0);
    }
    #endif // ENABLE_EDGE_FEEDBACK



    // -- BCS (Megatron Bezier in Yxy, no washout) --
    // In PIPELINE >= 1 the soop sandwich re-encodes to sRGB before this point.
    // apply_bcs expects a linear-ish input -- decode to linear first, then
    // re-encode after so the Bezier curve operates in the correct domain.
    if (abs(crt_brightness)>0.001 || abs(crt_contrast)>0.001 || abs(crt_saturation)>0.001)
    {
        #if PIPELINE >= 1
        float3 c_bcs_lin = to_linear(max(c, 0.0));
        c_bcs_lin = apply_bcs(c_bcs_lin, crt_brightness, crt_contrast, crt_saturation);
        c = from_linear(max(c_bcs_lin, 0.0));
        #else
        c = apply_bcs(c, crt_brightness, crt_contrast, crt_saturation);
        #endif
    }

    // -- CRT gamma decode --
    float3 c_lin = crt_to_linear(c);

    // -- Aperture grille mask --
    #if ENABLE_MASK
        // Moiré dither: small random sub-pixel phase offset per 16x16 tile.
        // Breaks strict mask periodicity that causes moiré with certain image
        // frequencies (Haeberli & Segal 1990).
        float2 tile_id  = floor(fc / 16.0);
        uint   tile_rng = grain_uhash(grain_uhash(uint(tile_id.y)) + uint(tile_id.x));
        float  dither_x = (float(tile_rng & 0xFFu) / 255.0 - 0.5) * crt_mask_dither;
        float2 fc_mask = fc + float2(phase_h + orbit_h + dither_x, 0.0);
        float  mask_pixel_luma = dot(max(c, 0.0), float3(0.2126, 0.7152, 0.0722));
        float3 mask = crt_mask_apply(fc_mask, crt_triad_width, crt_mask_strength,
                                    crt_phosphor_sharpness, crt_phosphor_colour,
                                    crt_mask_type, crt_slot_mask_strength,
                                    crt_mask_offset_x, crt_mask_offset_y, fc,
                                    mask_pixel_luma);
        // Phosphor dot structure: subtle per-dot luminance variation
        if (crt_phosphor_dot > 0.001)
        {
            uint dot_seed = uint(fc_mask.x) * 2333u + uint(fc_mask.y) * 3571u;
            float dot_var = grain_unorm1(grain_uhash(dot_seed)) * 2.0 - 1.0;
            mask *= 1.0 + dot_var * crt_phosphor_dot;
            mask  = max(mask, 0.0);
        }
        c_lin = c_lin * mask * crt_mask_boost;
    #endif

    // -- Scanlines with sub-pixel AA --
    // No vertical burn-in offset applied -- any vertical shift changes brightness
    // because frac() maps non-linearly to the gaussian beam profile.
    // Horizontal mask shift (phase_h + orbit_h) handles burn-in protection instead.
    // Resolution-independent scanline width.
    // When SCANLINE_REFERENCE_HEIGHT > 0, scale width proportionally so
    // the same crt_scanline_width value produces identical-looking scanlines
    // at any render resolution.
    #if SCANLINE_REFERENCE_HEIGHT > 0
    float scan_width = crt_scanline_width *
                       (float(BUFFER_HEIGHT) / float(SCANLINE_REFERENCE_HEIGHT));
    #else
    float scan_width = crt_scanline_width;
    #endif
    // Snap to nearest integer: non-integer scan_width causes some rows to
    // get f near 0 (bright) and others near ±0.5 (dark), producing oscillating
    // scanline sizes and inconsistent mask darkness as width increases.
    scan_width = max(round(scan_width), 1.0);

    // Interlace: shift scanline phase by half a scanline width every other frame.
    // Alternates which rows are bright/dark, simulating CRT interlaced mode.
    // Applied here (to the scanline period) not as a UV shift, so the actual
    // dark gaps between scanlines move position rather than the whole image shifting.
    // Snap to integer pixel coordinates before scanline calculation
    // to avoid floating point precision errors at period boundaries.
    float scanline_y = floor(fc.y) + 0.5;
    float f  = frac(scanline_y / scan_width) - 0.5;
    float fw = fwidth(fc.y / scan_width);
    float fa = f - fw * 0.5;
    float fb = f + fw * 0.5;
    float da = abs(fa) * 2.0;
    float db = abs(fb) * 2.0;

    #if ENABLE_BEAM_MODULATION
        // Luminance-dependent beam width. Sigma is in normalised scanline-period
        // units where f ∈ [-0.5, 0.5]. Scale by 1/scan_width converts from pixel
        // units so sigma=1.0 = 1 pixel regardless of scanline width.
        // For a dark gap: gauss(0.5, sigma_norm) must be near 0.
        // This requires sigma_norm < 0.2 -- i.e. sigma_pixels < 0.2*scan_width.
        float sigma_scale = 1.0 / max(scan_width, 1.0);
        float r_sigma = lerp(crt_beam_min_sigma, crt_beam_max_sigma, saturate(c_lin.r)) * sigma_scale;
        float g_sigma = lerp(crt_beam_min_sigma, crt_beam_max_sigma, saturate(c_lin.g)) * sigma_scale;
        float b_sigma = lerp(crt_beam_min_sigma, crt_beam_max_sigma, saturate(c_lin.b)) * sigma_scale;
        float beam_r = 0.5*(gauss(fa, r_sigma) + gauss(fb, r_sigma));
        float beam_g = 0.5*(gauss(fa, g_sigma) + gauss(fb, g_sigma));
        float beam_b = 0.5*(gauss(fa, b_sigma) + gauss(fb, b_sigma));
    #else
        float beam_r = 0.5*(megatron_scanline(c_lin.r,da,crt_r_scanline_min,crt_r_scanline_max,crt_r_scanline_attack)*gauss(fa,crt_scanline_sigma)
                           +megatron_scanline(c_lin.r,db,crt_r_scanline_min,crt_r_scanline_max,crt_r_scanline_attack)*gauss(fb,crt_scanline_sigma));
        float beam_g = 0.5*(megatron_scanline(c_lin.g,da,crt_g_scanline_min,crt_g_scanline_max,crt_g_scanline_attack)*gauss(fa,crt_scanline_sigma)
                           +megatron_scanline(c_lin.g,db,crt_g_scanline_min,crt_g_scanline_max,crt_g_scanline_attack)*gauss(fb,crt_scanline_sigma));
        float beam_b = 0.5*(megatron_scanline(c_lin.b,da,crt_b_scanline_min,crt_b_scanline_max,crt_b_scanline_attack)*gauss(fa,crt_scanline_sigma)
                           +megatron_scanline(c_lin.b,db,crt_b_scanline_min,crt_b_scanline_max,crt_b_scanline_attack)*gauss(fb,crt_scanline_sigma));
    #endif

    c_lin *= lerp(1.0, float3(beam_r, beam_g, beam_b), crt_scanline_strength);

    // -- Interlaced field blanking --
    // Alternate between odd and even scanline fields each frame, matching
    // how real CRT interlacing works: one field of scanlines is bright,
    // the other is dark, alternating every frame to create field-rate flicker.
    //
    // Blanking operates on scanline periods (not pixels) so it works correctly
    // at any scanline width. Uses the same scan_width as the scanline calculation.
    #if ENABLE_INTERLACE
    if (crt_interlace_strength > 0.001)
    {
        // Which field is this frame: 0 or 1, alternates every frame.
        // When BFI/decay is active, FRAMECOUNT increments every frame including
        // dark frames -- so lit frames may always land on even or odd FRAMECOUNT.
        // Divide by BFI cycle length so the field alternates per lit frame pair.
        #if ENABLE_DECAY
        uint  frame_field  = (FRAMECOUNT / uint(max(crt_decay_frames, 2))) & 1u;
        #else
        uint  frame_field  = FRAMECOUNT & 1u;
        #endif

        // Which scanline period does this pixel belong to: even or odd.
        // Snap scan_width to nearest integer so periods are whole pixels --
        // non-integer widths cause drift in the alternating pattern.
        float snap_width   = max(round(scan_width), 1.0);
        uint  scanline_idx = uint(fc.y / snap_width);
        uint  scan_field   = scanline_idx & 1u;

        // gate=1: full brightness (this field's scanline). gate=0: dimmed.
        float gate = (scan_field == frame_field) ? 1.0 : 0.0;
        float dim  = lerp(1.0, gate, crt_interlace_strength);
        c_lin *= dim;
    }
    #endif

    // -- Spot size / overbrightness --
    // Luminance-squared boost: dark pixels unaffected, bright pixels boosted.
    // Applied directly to c_lin before gamma re-encoding.
    // Debug: at spot_size=3.0 with full-white input, output is 4x brightness.
    if (crt_spot_size > 0.001)
    {
        float luma_s    = dot(c_lin, float3(0.2126, 0.7152, 0.0722));
        float luma_norm = saturate(luma_s); // clamp for gate
        float boost     = 1.0 + crt_spot_size * luma_norm * luma_norm;
        c_lin *= boost;
    }

    // -- Electron beam horizontal bloom --
    // On real CRTs, high-current beams (bright content) spread horizontally
    // due to space charge repulsion between electrons. Simulated as a
    // luminance-gated 3-tap horizontal blur on the post-scanline signal.
    if (crt_beam_h_bloom > 0.001)
    {
        float  luma_bl  = dot(c_lin, float3(0.2126, 0.7152, 0.0722));
        // Gate: only active above 70% luma, full effect above 90%
        float  gate_bl  = smoothstep(0.7, 0.9, luma_bl);
        if (gate_bl > 0.001)
        {
            float  bpx  = ReShade::PixelSize.x;
            float3 cl   = tex2D(ReShade::BackBuffer, texcoord - float2(bpx, 0.0)).rgb;
            float3 cr   = tex2D(ReShade::BackBuffer, texcoord + float2(bpx, 0.0)).rgb;
            // Convert neighbours to linear
            cl = glin(cl); cr = glin(cr);
            // Gaussian 3-tap: weights 0.25, 0.5, 0.25
            float3 bloomed = cl * 0.25 + c_lin * 0.5 + cr * 0.25;
            c_lin = lerp(c_lin, bloomed, gate_bl * crt_beam_h_bloom);
        }
    }

    // -- Re-encode --
    c = crt_from_linear(c_lin);

    // -- Brightboost (hue-preserving) --
    if (crt_bb_mode == 0)
    {
        // Peak channel mode: colour-agnostic, correct for CRT phosphor physics
        float bb_ref    = max(max(c.r, c.g), c.b);
        float bb_gain   = lerp(crt_bb_dark, crt_bb_bright, bb_ref);
        float bb_out    = bb_ref * bb_gain;
        c = (bb_ref > 0.0001) ? c * (bb_out / bb_ref) : c;
    }
    else if (crt_bb_mode == 1)
    {
        // Luma mode: perceptually weighted (Rec.709), may under-represent blue
        float bb_luma   = dot(c, float3(0.2126, 0.7152, 0.0722));
        float bb_ref    = max(max(c.r, c.g), c.b);
        float bb_gain   = lerp(crt_bb_dark, crt_bb_bright, bb_ref);
        float bb_out    = bb_luma * bb_gain;
        c = (bb_luma > 0.0001) ? c * (bb_out / bb_luma) : c;
    }
    else
    {
        // Per channel mode: each channel boosted by its own value independently.
        // Eliminates the peak-channel bias that causes warm/cool hue shifts at
        // high bb_dark values. Each channel sits at its own point on the
        // lerp(bb_dark, bb_bright, channel) curve.
        float3 bb_gain3 = lerp(crt_bb_dark, crt_bb_bright, c);
        c *= bb_gain3;
    }

    // -- Vignette --
    #if ENABLE_VIGNETTE
    if (crt_vignette_strength > 0.001)
    {
        float2 uv_c = texcoord * 2.0 - 1.0; // [-1,1] on both axes

        float vig;
        if (crt_vignette_shape == 1)
        {
            // Circular/elliptical: original dot(uv,uv) radial falloff.
            // Produces an oval on 16:9 (touches top/bottom before sides).
            vig = pow(saturate(1.0 - dot(uv_c, uv_c) * 0.5), crt_vignette_power);
        }
        else
        {
            // Rectangular CRT-authentic: independent H and V power-curve falloffs.
            // Corners naturally darker as product of both falloffs.
            float vig_h = pow(saturate(1.0 - abs(uv_c.x)), crt_vignette_power);
            float vig_v = pow(saturate(1.0 - abs(uv_c.y)), crt_vignette_v_power);
            vig = vig_h * vig_v;
        }
        // Highlight protection: pixels above threshold are progressively lifted
        // toward no-vignette. Strength controls maximum protection at threshold.
        float vig_luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        float protect  = saturate((vig_luma - crt_vignette_hdr_threshold) /
                                   max(1.0 - crt_vignette_hdr_threshold, 0.001));
        // protect=0 below threshold (full vig), =1 at peak brightness
        // Scale by strength so user controls maximum protection level
        float vig_gate = 1.0 - protect * crt_vignette_hdr_strength;
        vig = lerp(1.0, vig, vig_gate);
        vig = lerp(1.0, vig, crt_vignette_strength);
        c *= vig;
    }
    #endif // ENABLE_VIGNETTE

    // -- Corner shadow: bezel-cast darkening at screen extremes --
    #if ENABLE_CORNER_ROUND
    if (crt_corner_shadow > 0.001)
    {
        float2 edge  = abs(texcoord - 0.5) * 2.0; // 0=centre, 1=edge
        float  shadow = pow(max(edge.x, edge.y), 6.0);
        c *= 1.0 - shadow * crt_corner_shadow;
    }
    #endif

    // -- Halation (bright element glass scatter, localised) --
    #if ENABLE_HALATION
    if (crt_halation_strength > 0.001)
    {
        // Bilinear fetch from quarter-res texture -- hardware filtering gives
        // additional free smoothing on top of the blur
        // Use the V-blurred result (H then V) for true 2D anisotropic halation.
        // At anisotropy=1.0 both H and V sigma are equal -- isotropic, same as before.
        float3 halo = tex2D(crt_halation_v_sampler, texcoord).rgb;
        // Only add halation where the current pixel is darker than the halo
        // This prevents bright areas from blooming into themselves
        float cur_luma  = dot(c, float3(0.2126, 0.7152, 0.0722));
        float halo_luma = dot(halo, float3(0.2126, 0.7152, 0.0722));
        float gate      = saturate(halo_luma - cur_luma);
        c += halo * gate * crt_halation_strength;
    }
    #endif

    // -- Interference: rolling scanlines and animated chromatic ghosting --


    // -- Glow (tight + wide dual-scale bloom) --
    if (crt_glow_strength > 0.001 || crt_glow_wide_strength > 0.001)
    {
        float2 glow_uv = texcoord;
        if (crt_glow_strength > 0.001)
        {
            float3 glow = tex2D(crt_glow_v_sampler, glow_uv).rgb;
            c += crt_glow_strength * glow;
        }
        if (crt_glow_wide_strength > 0.001)
        {
            float3 wide_glow = tex2D(crt_glow_wide_v_sampler, glow_uv).rgb;
            c += crt_glow_wide_strength * wide_glow;
        }
    }

    color = float4(c, 1.0);
}

// ============================================================
// Edge blur pass: Radial optical defocus
// 8-tap Poisson disc scaled by distance from centre.
// Simulates CRT glass softening at beam edges.
// Centre is sharp, corners are defocused.
// Fixed 8 taps regardless of strength -- no quality slider needed.
// ============================================================

#if ENABLE_EDGE_BLUR
void crt_edge_blur_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    if (crt_edge_blur_strength < 0.001)
    {
        color = tex2D(ReShade::BackBuffer, texcoord);
        return;
    }

    // Distance from centre [0, ~0.707 at corner]
    float2 uv_c     = texcoord - 0.5;
    // Correct for aspect ratio so falloff is circular not elliptical
    uv_c.x         *= float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
    float  dist     = length(uv_c);

    // Blur amount: zero at centre, grows as power of distance
    float  blur_amt = pow(dist * 2.0, crt_edge_blur_falloff) *
                      crt_edge_blur_strength * crt_edge_blur_radius;

    // 8-tap Poisson disc -- fixed quality, cheap
    // Offsets in pixel space, rotated for good coverage
    float2 px = ReShade::PixelSize * blur_amt;
    static const float2 kDisc[8] = {
        float2( 0.000,  1.000),
        float2( 0.707,  0.707),
        float2( 1.000,  0.000),
        float2( 0.707, -0.707),
        float2( 0.000, -1.000),
        float2(-0.707, -0.707),
        float2(-1.000,  0.000),
        float2(-0.707,  0.707)
    };

    float3 result = tex2D(ReShade::BackBuffer, texcoord).rgb;
    for (int i = 0; i < 8; i++)
        result += tex2D(ReShade::BackBuffer, texcoord + kDisc[i] * px).rgb;
    result /= 9.0;

    color = float4(result, 1.0);
}
#endif



// ============================================================
// Film Grain: Compute shader path (Poisson Analog Film Grain)
// Self-contained -- all required functions inlined, no external includes.
// ============================================================

#if ENABLE_GRAIN
// ============================================================
// Grain pass (merged): Snapshot + delta in one dual-output pass
// Output 0 -> crt_pregrain_tex (clean snapshot)
// Output 1 -> crt_grain_raw_tex (grain delta)
// Saves one full-res pass vs separate snapshot + raw passes.
// ============================================================

void crt_grain_merged_PS(
    in  float4 position  : SV_Position,
    in  float2 texcoord  : TEXCOORD0,
    out float4 out_clean : SV_Target0,
    out float4 out_delta : SV_Target1)
{
    float3 c  = tex2D(ReShade::BackBuffer, texcoord).rgb;
    out_clean = float4(c, 1.0);
    float3 delta = float3(0.5, 0.5, 0.5);

    if (crt_grain_intensity > 0.001)
    {
        uint2  p   = uint2(texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT));
        float3 cl  = glin(c);
        float  luma_g = dot(cl, float3(0.2126, 0.7152, 0.0722));

        uint rng = grain_uhash(grain_uhash(p.y) + p.x);
        if (crt_grain_animate) rng += FRAMECOUNT;

        float3 u3 = float3(grain_next2(rng), grain_next1(rng));
        float3 gn = grain_bm3(u3);

        // Improvement 2: Poisson variance replaces shadow_gate.
        // Grain amplitude follows luma*(1-luma)/N -- peaks at midtones,
        // rolls off in both shadows AND highlights (physically correct).
        // shadow_gate only reduced grain in shadows, leaving highlights too crunchy.
        float poisson_amp = grain_poisson_sigma(luma_g, crt_grain_intensity);
        // Blend with user shadow control: crt_grain_shadows still works
        // as a shadow floor but the highlight rolloff is now automatic.
        float shadow_blend = lerp(crt_grain_shadows, 1.0, saturate(luma_g * 8.0));
        poisson_amp *= shadow_blend;

        float3 cl_grained;
        if (crt_grain_colour)
        {
            cl_grained = grain_hdr(cl);
            cl_grained += gn * poisson_amp;
            cl_grained = grain_sdr(cl_grained);
        }
        else
        {
            float grey = dot(cl, float3(0.2126, 0.7152, 0.0722));
            float grey3 = grain_hdr(grey.xxx).x;
            grey3 += gn.x * poisson_amp;
            grey3 = grain_sdr(grey3.xxx).x;
            float orig = dot(cl, float3(0.2126, 0.7152, 0.0722));
            cl_grained = (orig > 0.0001) ? cl * (grey3 / orig) : cl;
        }
        delta = (genc(cl_grained) - c) * 0.5 + 0.5;
    }

    // Temporal grain correlation: blend previous frame's grain into static areas.
    // Real film grain has temporal coherence -- the silver halide crystals are
    // physically fixed on the film stock, so static scenes see consistent grain.
    // Motion mask from prev1_tex: large difference = motion = fresh grain.
    out_delta = float4(delta, 1.0);
}

// Legacy single-output stubs kept for reference but no longer used in technique
void crt_pregrain_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    color = tex2D(ReShade::BackBuffer, texcoord);
}

void crt_grain_raw_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 c  = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float2 fc = texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT);
    float3 delta = float3(0.5, 0.5, 0.5);

    if (crt_grain_intensity > 0.001)
    {
        uint2  p   = uint2(fc);
        uint   rng = grain_uhash(grain_uhash(p.y) + p.x);
        if (crt_grain_animate) rng += FRAMECOUNT;
        float3 u3     = float3(grain_next2(rng), grain_next1(rng));
        float3 gn     = grain_bm3(u3);
        float3 cl     = glin(c);
        float  luma_g = dot(cl, float3(0.2126, 0.7152, 0.0722));
        float  poisson_amp = grain_poisson_sigma(luma_g, crt_grain_intensity);
        poisson_amp *= lerp(crt_grain_shadows, 1.0, saturate(luma_g * 8.0));
        float3 cl_grained;
        if (crt_grain_colour)
        {
            cl_grained = grain_hdr(cl);
            cl_grained += gn * poisson_amp;
            cl_grained = grain_sdr(cl_grained);
        }
        else
        {
            float grey = dot(cl, float3(0.2126, 0.7152, 0.0722));
            float grey3 = grain_hdr(grey.xxx).x;
            grey3 += gn.x * poisson_amp;
            grey3 = grain_sdr(grey3.xxx).x;
            float orig = dot(cl, float3(0.2126, 0.7152, 0.0722));
            cl_grained = (orig > 0.0001) ? cl * (grey3 / orig) : cl;
        }
        delta = (genc(cl_grained) - c) * 0.5 + 0.5;
    }
    else
    {
        delta = float3(0.5, 0.5, 0.5); // neutral (zero delta)
    }

    color = float4(delta, 1.0);
}

// ============================================================
// Grain pass 2: Diffuse the delta, add back to clean image
// Blurs only the grain delta (not the image), then composites.
// This is the correct approach: diffusion softens grain clumps
// without affecting underlying image sharpness.
// ============================================================

void crt_grain_diffuse_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 clean = tex2D(crt_pregrain_samp, texcoord).rgb;

    if (crt_grain_intensity < 0.001)
    {
        color = float4(clean, 1.0);
        return;
    }

    float2 px = ReShade::PixelSize;
    float2 fc = texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT);

    // Sigma: tight diffusion -- the organic look comes from Morton spatial correlation,
    // not from blurring. Keep sigma small so individual grain pixels stay sharp.
    float sigma = lerp(0.3, 1.5, crt_grain_size);

    float3 diffused_delta;

    if (crt_grain_size < 0.001)
    {
        diffused_delta = tex2D(crt_grain_raw_samp, texcoord).rgb;
    }
    else
    {
        float3 result = 0.0;
        float  wsum   = 0.0;

        for (int x = -1; x <= 1; x++)
        for (int y = -1; y <= 1; y++)
        {
            float2 tp  = float2(float(x), float(y));
            float2 uv  = texcoord + tp * px;
            float3 d   = tex2D(crt_grain_raw_samp, uv).rgb;

            uint2  pi  = uint2(uv * float2(BUFFER_WIDTH, BUFFER_HEIGHT));
            uint   rng = grain_uhash(grain_uhash(pi.y) + pi.x);
            if (crt_grain_animate) rng += FRAMECOUNT;
            float2 rand01 = float2(rng & 31u, rng >> 5u) / 32.0;
            float2 bm     = grain_boxmuller_2d(rand01) * sigma;
            float2 offs   = tp + bm;

            float w = exp(-dot(offs, offs));

            result += d * w;
            wsum   += w;
        }
        diffused_delta = result / max(wsum, 1e-5);
    }

    // Decode delta from [0,1] storage back to signed [-0.5, 0.5]
    float3 grain = (diffused_delta - 0.5) * 2.0;

    // Add diffused grain delta to clean pre-grain image
    color = float4(saturate(clean + grain), 1.0);
}

#endif // ENABLE_GRAIN

// ============================================================
// Post-scanline vertical softening pass
// Tiny vertical gaussian to smooth scanline-edge intersections
// on curved geometry. Asymmetric -- slightly stronger below
// to match natural phosphor spread direction.
// ============================================================

#if ENABLE_SCANLINE_SOFTEN
void crt_soften_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    if (crt_soften_strength < 0.001)
    {
        color = tex2D(ReShade::BackBuffer, texcoord);
        return;
    }
    float py    = ReShade::PixelSize.y;
    float sigma = crt_soften_strength * 0.8;

    // 5-tap asymmetric vertical gaussian
    // Slight downward bias matches CRT beam sweep direction
    float w0 = gauss(0.0,  sigma);
    float w1 = gauss(1.0,  sigma);
    float w2 = gauss(2.0,  sigma);
    float w1d = gauss(0.8, sigma); // slightly closer below
    float w2d = gauss(1.8, sigma);

    float3 c =
        tex2D(ReShade::BackBuffer, texcoord + float2(0.0, -2.0*py)).rgb * w2  +
        tex2D(ReShade::BackBuffer, texcoord + float2(0.0, -1.0*py)).rgb * w1  +
        tex2D(ReShade::BackBuffer, texcoord).rgb                         * w0  +
        tex2D(ReShade::BackBuffer, texcoord + float2(0.0,  1.0*py)).rgb * w1d +
        tex2D(ReShade::BackBuffer, texcoord + float2(0.0,  2.0*py)).rgb * w2d;

    float wsum = w2 + w1 + w0 + w1d + w2d;
    color = float4(c / wsum, 1.0);
}
#endif

// ============================================================
// Contrast-adaptive sharpening pass
// Sharpens edges without amplifying noise or flat areas.
// Based on AMD CAS approach: compare pixel to neighbourhood,
// apply sharpening proportional to local contrast.
// ============================================================

#if ENABLE_SHARPEN
void crt_sharpen_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    if (crt_sharpen_strength < 0.001)
    {
        color = tex2D(ReShade::BackBuffer, texcoord);
        return;
    }
    float2 px = ReShade::PixelSize;

    float3 c  = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float3 n  = tex2D(ReShade::BackBuffer, texcoord + float2( 0.0, -px.y)).rgb;
    float3 s  = tex2D(ReShade::BackBuffer, texcoord + float2( 0.0,  px.y)).rgb;
    float3 e  = tex2D(ReShade::BackBuffer, texcoord + float2( px.x, 0.0)).rgb;
    float3 w  = tex2D(ReShade::BackBuffer, texcoord + float2(-px.x, 0.0)).rgb;

    // Diagonal neighbours for more accurate local contrast estimate.
    // AMD full CAS uses 8-neighbour min/max for the weight computation
    // while keeping the 4-axis sharpening kernel -- better on diagonal edges.
    float3 ne = tex2D(ReShade::BackBuffer, texcoord + float2( px.x, -px.y)).rgb;
    float3 nw = tex2D(ReShade::BackBuffer, texcoord + float2(-px.x, -px.y)).rgb;
    float3 se = tex2D(ReShade::BackBuffer, texcoord + float2( px.x,  px.y)).rgb;
    float3 sw = tex2D(ReShade::BackBuffer, texcoord + float2(-px.x,  px.y)).rgb;

    // Local min/max across all 8 neighbours (contrast estimate only)
    float3 mn = min(min(min(n, s), min(e, w)), min(min(ne, nw), min(se, sw)));
    float3 mx = max(max(max(n, s), max(e, w)), max(max(ne, nw), max(se, sw)));
    mn = min(mn, c); mx = max(mx, c);

    // Normalise range relative to peak -- makes weight HDR-safe
    // Without normalisation, large HDR values cause near-division-by-zero
    float3 rng      = mx - mn;
    float3 rng_norm = rng / (mx + 0.001);
    float3 w_cas    = -rng_norm / (4.0 - 2.0 * rng_norm + 0.001);
    w_cas = clamp(w_cas, -crt_sharpen_clamp, 0.0) * crt_sharpen_strength;

    float3 sharpened = (c + (n + s + e + w) * w_cas) / (1.0 + 4.0 * w_cas);
    color = float4(max(sharpened, 0.0), 1.0);
}
#endif

// ============================================================
// Motion-adaptive sharpening pass
// Uses frame difference (current vs prev1_tex) as a motion mask.
// CAS sharpening is applied with strength proportional to per-pixel
// motion magnitude -- moving areas get sharpened, static areas don't.
// Requires ENABLE_DECAY=1 for prev1_tex to be populated.
// ============================================================
#if ENABLE_MOTION_SHARPEN
void crt_motion_sharpen_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float2 px = ReShade::PixelSize;

    float3 c = tex2D(ReShade::BackBuffer, texcoord).rgb;

    // Motion magnitude: luma difference between current and previous frame.
    // prev1_tex holds the pre-decay raw frame from last frame's store pass.
    // If ENABLE_DECAY is off, prev1 is uninitialised -- guard with the define.
    #if ENABLE_DECAY
    float3 prev     = tex2D(crt_decay_prev1_sampler, texcoord).rgb;
    float  luma_c   = dot(c,    float3(0.2126, 0.7152, 0.0722));
    float  luma_p   = dot(prev, float3(0.2126, 0.7152, 0.0722));
    float  motion   = saturate((abs(luma_c - luma_p) - crt_msharpen_motion_threshold)
                               / max(crt_msharpen_motion_threshold, 0.001));
    #else
    float motion = 1.0; // no motion data -- apply uniformly
    #endif

    // CAS sharpening weighted by motion magnitude
    float effective_strength = crt_msharpen_strength * motion;

    if (effective_strength < 0.001)
    {
        color = float4(c, 1.0);
        return;
    }

    float3 n = tex2D(ReShade::BackBuffer, texcoord + float2( 0.0, -px.y)).rgb;
    float3 s = tex2D(ReShade::BackBuffer, texcoord + float2( 0.0,  px.y)).rgb;
    float3 e = tex2D(ReShade::BackBuffer, texcoord + float2( px.x,  0.0)).rgb;
    float3 w = tex2D(ReShade::BackBuffer, texcoord + float2(-px.x,  0.0)).rgb;

    float3 mn       = min(min(min(n, s), min(e, w)), c);
    float3 mx       = max(max(max(n, s), max(e, w)), c);
    float3 rng      = mx - mn;
    float3 rng_norm = rng / (mx + 0.001);
    float3 w_cas    = -rng_norm / (4.0 - 2.0 * rng_norm + 0.001);
    w_cas = clamp(w_cas, -crt_msharpen_clamp, 0.0) * effective_strength;

    float3 sharpened = (c + (n + s + e + w) * w_cas) / (1.0 + 4.0 * w_cas);
    color = float4(max(sharpened, 0.0), 1.0);
}
#endif

// ============================================================
// Phosphor persistence pass
// Blends a downward-offset copy of the image at low opacity
// to simulate phosphor decay trailing below each scanline.
// Also stores current frame for next frame blend.
// ============================================================

#if ENABLE_PERSISTENCE
void crt_persistence_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 current = tex2D(ReShade::BackBuffer, texcoord).rgb;

    if (crt_persistence_strength < 0.001)
    {
        color = float4(current, 1.0);
        return;
    }

    // Sample from above -- the phosphor trail appears below the beam
    // The beam scans top to bottom, so pixels above were lit slightly earlier
    // and their phosphor emission trails downward
    float py       = ReShade::PixelSize.y * crt_persistence_decay;
    float3 above   = tex2D(ReShade::BackBuffer, texcoord - float2(0.0, py)).rgb;

    // Per-channel persistence: R/G/B have different phosphor decay rates.
    // Green persists longest (P22 ~2-3ms), red intermediate, blue shortest (~0.5ms).
    // crt_persistence_r/g/b override per-channel; if all zero, fall back to uniform.
    float3 cur_lin   = glin(current);
    float3 above_lin = glin(above);

    // Per-channel blend weights: use per-channel if any non-zero, else uniform
    float use_perchannel = max(max(crt_persistence_r, crt_persistence_g), crt_persistence_b);
    float3 blend = (use_perchannel > 0.001)
                 ? float3(crt_persistence_r, crt_persistence_g, crt_persistence_b)
                 : float3(crt_persistence_strength, crt_persistence_strength, crt_persistence_strength);

    float3 trail_lin = lerp(cur_lin, above_lin, blend);
    float3 trail     = genc(max(trail_lin, 0.0));
    // Only ever adds light -- never darkens
    color = float4(max(current, trail), 1.0);
}

void crt_persistence_store_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    color = tex2D(ReShade::BackBuffer, texcoord);
}
#endif

// ============================================================
// Pipeline: Soop Before/After passes
// ============================================================

#if PIPELINE >= 1
void crt_soop_before_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 c = tex2D(ReShade::BackBuffer, texcoord).rgb;
#if PIPELINE == 1
    // scRGB: apply Reinhard compression with shadow gamma lift
    c = soop_reinhard(c, crt_soop_peak_nits, crt_soop_shadow_gamma);
#elif PIPELINE == 2
    // HDR10: PQ decode to linear, then Reinhard compress
    c = soop_pq_to_linear(c, crt_soop_hdr10_peak_nits);
    c = soop_reinhard_simple(c);
    c = soop_linear_to_srgb(c);
#endif
    color = float4(c, 1.0);
}

void crt_soop_after_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 c = tex2D(ReShade::BackBuffer, texcoord).rgb;
#if PIPELINE == 1
    // scRGB: apply InvReinhard to restore HDR range
    c = soop_inv_reinhard(c, crt_soop_shadow_gamma);
#elif PIPELINE == 2
    // HDR10: sRGB to linear, InvReinhard, then PQ encode
    c = soop_srgb_to_linear(c);
    c = soop_inv_reinhard_simple(c);
    c = soop_linear_to_pq(c, crt_soop_hdr10_peak_nits);
#endif
    color = float4(c, 1.0);
}
#endif // PIPELINE >= 1

// ============================================================
// Geometry: barrel distortion (final pass UV warp)
// Simulates CRT glass curvature. Applied after all CRT processing
// so scanlines and mask remain geometrically straight (physically correct).
// No corner masking -- pixels at edges clamp to edge colour, stay lit.
// ============================================================

#if ENABLE_GEOMETRY
// Geometry: pincushion/barrel UV warp simulating CRT screen curvature
// Mode 1 (Spherical): curves both H and V -- classic consumer CRT
// Mode 2 (Alt Spherical): stronger corner distortion
// Mode 3 (Cylindrical/Trinitron): horizontal curvature only, V stays straight
// Based on crt-geom pincushion formula -- no 3D projection needed.
// Corners are clamped to edge colour, no black masking, all pixels lit.
void crt_geometry_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    if (crt_geom_mode == 0)
    {
        color = tex2D(ReShade::BackBuffer, texcoord);
        return;
    }

    // Map to -1..1, apply zoom (scale UV so values > 1.0 zoom in)
    float2 uv = (texcoord * 2.0 - 1.0) / crt_geom_zoom;

    // Aspect ratio -- needed so curvature appears circular not elliptical
    float ar = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
    uv.x *= ar;

    float cv = crt_geom_curvature; // divisor -- smaller = more curved

    if (crt_geom_mode == 1)
    {
        // Spherical: pincushion on both axes
        uv.x *= 1.0 + (uv.y * uv.y) / (cv * cv);
        uv.y *= 1.0 + (uv.x * uv.x) / (cv * cv * ar * ar);
    }
    else if (crt_geom_mode == 2)
    {
        // Alt Spherical: stronger distortion -- power of 1.5 instead of 2
        uv.x *= 1.0 + pow(abs(uv.y) / cv, 1.5);
        uv.y *= 1.0 + pow(abs(uv.x) / (cv * ar), 1.5);
    }
    else
    {
        // Cylindrical (Trinitron): horizontal curvature only
        // Vertical axis stays perfectly straight
        uv.x *= 1.0 + (uv.y * uv.y) / (cv * cv);
        // uv.y unchanged
    }

    // Undo aspect correction
    uv.x /= ar;

    // Map back to 0..1, clamp to edge (no black corners, all pixels lit)
    float2 tc = clamp(uv * 0.5 + 0.5, 0.0, 1.0);
    color = tex2D(ReShade::BackBuffer, tc);
}
#endif// ============================================================
// Phosphor Decay pass (BFI-style motion clarity)
// Fibonacci-weighted exponential decay modulates current frame
// brightness based on position within the decay cycle.
// Based on CRT Dusha by Maxim Lapounov (MIT license)
// ============================================================

#if ENABLE_DECAY

// ============================================================
// Fibonacci sequence for decay weighting
static const float kFib[8] = { 1.0, 1.0, 2.0, 3.0, 5.0, 8.0, 13.0, 21.0 };

// Variable MPRT sRGB helpers (SDR path only)
// Uses hardcoded sRGB standard (gamma 2.4 / IEC 61966-2-1).
// No user-exposed gamma slider -- the sRGB transfer function is not a free parameter;
// changing it breaks the brightness-budget math.
static const float kDecayGamma = 2.4;
float bb_srgb2linear(float c)
{
    return (c <= 0.04045) ? c / 12.92 : pow((c + 0.055) / 1.055, kDecayGamma);
}
float3 bb_srgb2linear(float3 c)
{
    return float3(bb_srgb2linear(c.r), bb_srgb2linear(c.g), bb_srgb2linear(c.b));
}
float bb_linear2srgb(float c)
{
    // Standard IEC 61966-2-1 sRGB encode.
    // Below threshold: linear segment. Above: power curve.
    return (c <= 0.0031308)
        ? c * 12.92
        : pow(max(c, 0.0), 1.0 / kDecayGamma) * 1.055 - 0.055;
}
float3 bb_linear2srgb(float3 c)
{
    return float3(bb_linear2srgb(c.r), bb_linear2srgb(c.g), bb_linear2srgb(c.b));
}

// Phase store: write raw cycle index as a normalised float in [0,1].
// Encoding: index / (MAX_FRAMES - 1) so R8 precision covers 2..8 frames cleanly.
// MAX_FRAMES must match the ui_max of crt_decay_frames (8).
#define DECAY_MAX_FRAMES 8
// Shared luma sampler for monitor -- samples post-decay backbuffer at 9 points.
float crt_decay_sample_luma()
{
    float luma = 0.0;
    [unroll] for (int sy = 0; sy < 3; sy++)
    [unroll] for (int sx = 0; sx < 3; sx++)
    {
        float3 s = tex2D(ReShade::BackBuffer, float2((sx + 0.5) / 3.0, (sy + 0.5) / 3.0)).rgb;
        luma += dot(s, float3(0.2126, 0.7152, 0.0722));
    }
    return luma / 9.0;
}

// Lit frame EMA monitor: only updates when frame_in_cycle == 0
void crt_decay_luma_lit_copy_PS(
    in  float4 pos : SV_Position, in float2 tc : TEXCOORD0,
    out float4 col : SV_Target) { col = tex2D(crt_decay_luma_lit_sampler, tc); }

void crt_decay_luma_dark_copy_PS(
    in  float4 pos : SV_Position, in float2 tc : TEXCOORD0,
    out float4 col : SV_Target) { col = tex2D(crt_decay_luma_dark_sampler, tc); }

void crt_decay_luma_lit_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    int frames        = max(crt_decay_frames, 2);
    float4 phase_data = tex2D(crt_decay_phase_sampler, float2(0.5, 0.5));
    int    fic        = int(round(phase_data.r * 255.0)) % frames;
    float  prev       = tex2D(crt_decay_luma_lit_prev_samp, float2(0.5, 0.5)).r;
    if (fic == 0)
        color = float4(lerp(prev, crt_decay_sample_luma(), 0.05), 0.0, 0.0, 1.0);
    else
        color = float4(prev, 0.0, 0.0, 1.0); // preserve
}

// Dark frame EMA monitor: only updates when frame_in_cycle != 0
void crt_decay_luma_dark_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    int frames        = max(crt_decay_frames, 2);
    float4 phase_data = tex2D(crt_decay_phase_sampler, float2(0.5, 0.5));
    int    fic        = int(round(phase_data.r * 255.0)) % frames;
    float  prev       = tex2D(crt_decay_luma_dark_prev_samp, float2(0.5, 0.5)).r;
    if (fic != 0)
        color = float4(lerp(prev, crt_decay_sample_luma(), 0.05), 0.0, 0.0, 1.0);
    else
        color = float4(prev, 0.0, 0.0, 1.0); // preserve
}

void crt_decay_phase_store_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    int frames = max(crt_decay_frames, 2);

    // Auto-resync: dark frame EMA should be near dark_floor, not near lit EMA.
    // If dark_avg > 40% of lit_avg the phase has flipped -- add 1 to correct.
    // Only meaningful for 2-frame BFI where lit/dark distinction is cleanest.
    int auto_offset = 0;
    if (crt_decay_auto_resync && frames == 2)
    {
        float lit_avg  = tex2D(crt_decay_luma_lit_sampler,  float2(0.5, 0.5)).r;
        float dark_avg = tex2D(crt_decay_luma_dark_sampler, float2(0.5, 0.5)).r;
        if (lit_avg > 0.01 && dark_avg > lit_avg * 0.40)
            auto_offset = 1;
    }

    int phase_offset = (crt_decay_fg_phase ? 1 : 0) + FRAMEGEN_PHASE_OFFSET + auto_offset;
    int idx          = (int(FRAMECOUNT) + phase_offset) % frames;
    color            = float4(float(idx) / 255.0, 0.0, 0.0, 1.0);
}

// Raw game frame store: captures backbuffer before decay modifies it.
// Must run as the FIRST decay pass -- before prev1/prev2 stores and the decay PS.
// Merged decay history store: three full-res copies in one dual-output pass.
// Saves two full-resolution passes vs three separate ones.
//   Target0 = crt_decay_raw_tex   (current backbuffer -- pre-decay raw frame)
//   Target1 = crt_decay_prev1_tex (current backbuffer -- becomes prev1 next frame)
// prev2 is updated separately since it reads from prev1 (last frame), not BackBuffer.
void crt_decay_store_PS(
    in  float4 position  : SV_Position,
    in  float2 texcoord  : TEXCOORD0,
    out float4 out_raw   : SV_Target0,
    out float4 out_prev1 : SV_Target1)
{
    float3 c  = tex2D(ReShade::BackBuffer, texcoord).rgb;
    out_raw   = float4(c, 1.0);
    out_prev1 = float4(c, 1.0);
}

// prev2 still needs a separate pass -- it reads from prev1 (previous frame's value)
// which is not available in the same pass as BackBuffer capture.
void crt_decay_prev2_store_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    color = float4(tex2D(crt_decay_prev1_sampler, texcoord).rgb, 1.0);
}



// ============================================================
// Main decay pass
// Key design decisions:
//   - Phase index: FRAMECOUNT % frames, stored /255, decoded *255
//   - Standard BFI (tubePos off): frame 0 lit at gain, others black
//   - BB integral (tubePos on, 240Hz+): spatial overlap over 1-texcoord.y
//   - HDR mode: hard BFI only, no sRGB conversion, no history frames
//   - Oscillation: FRAMECOUNT-based, no frametime division (ReShade 6.x safe)
//   - 30-second startup passthrough
// ============================================================
void crt_decay_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 c      = tex2D(ReShade::BackBuffer, texcoord).rgb;
    int    frames = max(crt_decay_frames, 2);

    // Decode phase index. Encoded as float(idx)/255.0 in phase store pass.
    float4 phase_data   = tex2D(crt_decay_phase_sampler, float2(0.5, 0.5));
    int    frame_in_cycle = int(round(phase_data.r * 255.0)) % frames;

    float3 out_color = float3(0.0, 0.0, 0.0);

    // BFI Duty Ratio: skip every N cycles, outputting passthrough instead.
    // Cycle index = FRAMECOUNT / frames (advances once per complete cycle).
    // When duty_ratio > 0: active on cycle % (duty_ratio+1) == 0, skip otherwise.
    // This is independent of frames-per-cycle -- the skip always spans one
    // complete cycle regardless of how many frames are in it.
    bool cycle_active = true;
    if (crt_decay_duty_ratio > 0)
    {
        int cycle_idx = int(FRAMECOUNT) / frames;
        cycle_active  = (cycle_idx % (crt_decay_duty_ratio + 1)) == 0;
    }

    // Frametime spike detection: if this frame took significantly longer than expected,
    // output passthrough instead of BFI. A spike frame held on-screen for 2-5x the
    // expected period causes a visible flash -- suppressing BFI for that frame
    // eliminates the flash entirely. The next frame resumes normal BFI.
    bool spike_frame = (CRT_FRAMETIME > CRT_FRAMETIME_EXPECTED * crt_decay_spike_threshold);

    // 30-second startup gate, duty ratio skip, and spike suppression all pass through.
    if (CRT_TIMER < 30000.0 || !cycle_active || spike_frame)
    {
        out_color = c;
    }
    else if (crt_decay_method == 0)
    {
        // ====================================================
        // Method 0: Fibonacci (uniform darkening)
        // ====================================================
        if (frame_in_cycle == 0)
        {
            out_color = c;
        }
        else
        {
            float t = float(frame_in_cycle) / float(frames - 1);

            float fib_sum = 0.0;
            float fib_w   = 0.0;
            int   stages  = max(crt_decay_stages, 1);
            [unroll]
            for (int s = 0; s < 8; s++)
            {
                if (s < stages)
                {
                    float w           = kFib[s];
                    float stage_decay = exp(-crt_decay_speed * kFib[s] * 0.1);
                    fib_sum += w * stage_decay;
                    fib_w   += w;
                }
            }
            float base_decay = (fib_w > 0.0) ? saturate(fib_sum / fib_w) : 0.0;

            const float PI_VAL  = 3.14159265;
            float sine_factor   = 0.5 + 0.5 * cos(PI_VAL * t);
            float hard_factor   = pow(base_decay, t);
            float smooth_factor = lerp(hard_factor, sine_factor, crt_decay_sine_blend);
            float floored       = max(smooth_factor, crt_decay_floor);

            float3 factor = float3(
                pow(max(floored, 0.001), crt_decay_r),
                pow(max(floored, 0.001), crt_decay_g),
                pow(max(floored, 0.001), crt_decay_b)
            );

            float luma     = dot(max(c, 0.0), float3(0.2126, 0.7152, 0.0722));
            float luma_mix = pow(saturate(luma), max(1.0 - crt_decay_luma_protect, 0.001));
            factor         = lerp(factor, float3(1.0, 1.0, 1.0), luma_mix * crt_decay_luma_protect);

            // Phosphor trail colour cast: tint the decayed trail component
            // trail = c*factor - c*1.0 (the "missing" brightness from decay)
            // Shift trail colour by adding a per-channel tint proportional to (1-factor)
            float3 trail_tint = float3(
                1.0 + crt_phosphor_trail_r * (1.0 - factor.r),
                1.0 + crt_phosphor_trail_g * (1.0 - factor.g),
                1.0 + crt_phosphor_trail_b * (1.0 - factor.b));
            out_color = c * factor * trail_tint;
        }
    }
    else if (crt_decay_method == 2)
    {
            // ====================================================
            // Method 2: BFI (Black Frame Insertion) -- HDR/linear path
            //
            // The BB overlap-integral algorithm requires input values
            // in bounded [0,1] linear space. In HDR (scRGB/PQ-decoded)
            // pipelines, values above 1.0 are legal -- a 1000-nit
            // highlight in an 80-nit reference is ~12.5 in scRGB linear.
            // Multiplying by (frames x gain) before the overlap math
            // inflates those values to 15-20+, and the final max(r,0)
            // clamp cannot rescue them. The result is catastrophically
            // blown highlights.
            //
            // Standard BFI is the correct HDR approach: on "lit" frames
            // the signal is boosted by (frames x gain) to compensate for
            // duty-cycle loss; on "dark" frames the output is black.
            // This is linear-safe at any signal magnitude.
            // ====================================================
            // Invert cycle: N-1 lit + 1 dark instead of 1 lit + N-1 dark.
            // Standard: frame 0 = lit, others = dark.
            // Inverted: frame 0 = dark, others = lit.
            // Duty cycle changes so adjust litGain accordingly.
            bool is_lit;
            float litGain;
            if (crt_decay_invert_cycle && frames > 2)
            {
                is_lit  = (frame_in_cycle != 0);
                // duty cycle = (frames-1)/frames, compensate: gain * frames/(frames-1)
                litGain = float(frames) * crt_decay_gain / max(float(frames - 1), 1.0);
            }
            else
            {
                is_lit  = (frame_in_cycle == 0);
                litGain = float(frames) * crt_decay_gain;
            }

            if (crt_decay_sine_bfi)
            {
                // Sine BFI: cosine phase. Invert shifts the peak to dark frame.
                float phase = (float(frame_in_cycle) / float(frames)) * 2.0 * 3.14159265;
                if (crt_decay_invert_cycle && frames > 2) phase += 3.14159265; // shift peak
                float sine_gain = lerp(crt_decay_dark_floor, litGain, 0.5 + 0.5 * cos(phase));
                #if PIPELINE >= 1
                    float3 lin = soop_inv_reinhard(c, crt_soop_shadow_gamma);
                    lin *= sine_gain;
                    out_color = soop_reinhard(lin, crt_soop_peak_nits, crt_soop_shadow_gamma);
                #else
                    float3 lin = bb_srgb2linear(c);
                    lin *= sine_gain;
                    out_color = clamp(bb_linear2srgb(lin), 0.0, 1.0);
                #endif
            }
            else if (is_lit)
            {
                // Lit frame: gain applied in linear space.
                #if PIPELINE >= 1
                    float3 lin = soop_inv_reinhard(c, crt_soop_shadow_gamma);
                    lin *= litGain;
                    out_color = soop_reinhard(lin, crt_soop_peak_nits, crt_soop_shadow_gamma);
                #else
                    float3 lin = bb_srgb2linear(c);
                    lin *= litGain;
                    out_color = clamp(bb_linear2srgb(lin), 0.0, 1.0);
                #endif
            }
            else
            {
                // Dark frame: flat floor or blended floor.
                if (crt_decay_dark_blend && crt_decay_dark_floor > 0.0)
                {
                    float3 prev = tex2D(crt_decay_prev1_sampler, texcoord).rgb;
                    out_color = lerp(prev, c, 0.5) * crt_decay_dark_floor;
                }
                else
                {
                    out_color = float3(crt_decay_dark_floor, crt_decay_dark_floor, crt_decay_dark_floor);
                }
            }
    }
    else
    {
            // ====================================================
            // Method 1: Variable MPRT (Blur Busters - SDR only)
            //
            // WARNING: This method uses the sRGB transfer function
            // (bb_srgb2linear / bb_linear2srgb) internally. It assumes
            // the backbuffer is standard gamma-encoded sRGB (PIPELINE 0).
            // On PIPELINE 1/2 the backbuffer holds Reinhard-compressed
            // scRGB -- decoding it with sRGB gamma produces wrong values
            // and remaps highlights incorrectly. Use BFI (method 2) for
            // PIPELINE 1/2.
            //
            // tubePos OFF: standard BFI in linear space. Default, 120Hz safe.
            // tubePos ON:  BB spatial overlap integral. 240Hz+ only.
            // ====================================================
            #if PIPELINE >= 1
            // Pipeline mismatch: output a red tint as a visible warning.
            // Switch to Decay Method = BFI to fix this.
            out_color = float3(c.r * 0.5 + 0.5, c.g * 0.3, c.b * 0.3);
            #else
            float3 pixelCurr      = bb_srgb2linear(c);
            float  brightnessScale = float(frames) * crt_decay_gain;

            if (!crt_decay_tube_pos)
            {
                // Apply same invert logic as method 2.
                bool m1_is_lit;
                float m1_scale;
                if (crt_decay_invert_cycle && frames > 2)
                {
                    m1_is_lit = (frame_in_cycle != 0);
                    m1_scale  = brightnessScale / max(float(frames - 1), 1.0);
                }
                else
                {
                    m1_is_lit = (frame_in_cycle == 0);
                    m1_scale  = brightnessScale;
                }

                if (crt_decay_sine_bfi)
                {
                    float phase = (float(frame_in_cycle) / float(frames)) * 2.0 * 3.14159265;
                    if (crt_decay_invert_cycle && frames > 2) phase += 3.14159265;
                    float sine_gain = lerp(crt_decay_dark_floor, m1_scale, 0.5 + 0.5 * cos(phase));
                    out_color = clamp(bb_linear2srgb(pixelCurr * sine_gain), 0.0, 1.0);
                }
                else if (m1_is_lit)
                    out_color = clamp(bb_linear2srgb(pixelCurr * m1_scale), 0.0, 1.0);
                else
                {
                    if (crt_decay_dark_blend && crt_decay_dark_floor > 0.0)
                    {
                        float3 prev = tex2D(crt_decay_prev1_sampler, texcoord).rgb;
                        out_color = lerp(prev, c, 0.5) * crt_decay_dark_floor;
                    }
                    else
                        out_color = float3(crt_decay_dark_floor, crt_decay_dark_floor, crt_decay_dark_floor);
                }
            }
            else
            {
                // BB overlap integral -- only valid with spatially-varying tubePos.
                float3 pixelPrev1 = bb_srgb2linear(tex2D(crt_decay_prev1_sampler, texcoord).rgb);
                float3 pixelPrev2 = bb_srgb2linear(tex2D(crt_decay_prev2_sampler, texcoord).rgb);

                float3 colorCurr  = pixelCurr  * brightnessScale;
                float3 colorPrev1 = pixelPrev1 * brightnessScale;
                float3 colorPrev2 = pixelPrev2 * brightnessScale;

                float crtRasterPos = float(frame_in_cycle) / float(frames);
                float tubePos      = 1.0 - texcoord.y;
                float tubeFrame    = tubePos * float(frames);
                float fStart       = crtRasterPos * float(frames);
                float fEnd         = fStart + 1.0;

                #define BB_CH_FUNC(Lc, Lp1, Lp2) \
                    max(0.0, min((tubeFrame - float(frames)) + (Lp2), fEnd) - max(tubeFrame - float(frames), fStart)) + \
                    max(0.0, min(tubeFrame + (Lp1), fEnd) - max(tubeFrame, fStart)) + \
                    max(0.0, min(tubeFrame + float(frames) + (Lc), fEnd) - max(tubeFrame + float(frames), fStart))

                // Scene-change: compare against the raw pre-decay game frame,
                // NOT prev1 (which holds post-decay output -- alternating lit/black --
                // and would fire the detector on every dark frame in the cycle).
                float3 rawPrev = bb_srgb2linear(tex2D(crt_decay_raw_sampler, texcoord).rgb);
                float lumaC    = dot(pixelCurr, float3(0.2126, 0.7152, 0.0722));
                float lumaP1   = dot(rawPrev,   float3(0.2126, 0.7152, 0.0722));

                float3 result;
                if (abs(lumaC - lumaP1) > crt_decay_scene_threshold)
                {
                    result = pixelCurr * brightnessScale;
                }
                else
                {
                    result = float3(
                        BB_CH_FUNC(colorCurr.r, colorPrev1.r, colorPrev2.r),
                        BB_CH_FUNC(colorCurr.g, colorPrev1.g, colorPrev2.g),
                        BB_CH_FUNC(colorCurr.b, colorPrev1.b, colorPrev2.b)
                    );
                }
                #undef BB_CH_FUNC

                out_color = clamp(bb_linear2srgb(result), 0.0, 1.0);
            }
            #endif // PIPELINE >= 1 mismatch guard
    }

    color = float4(out_color, 1.0);
}

#endif
// ============================================================
// Technique
// ============================================================

// ============================================================
// Composite video pass -- Y/C separation with independent luma/chroma bandwidth
// ============================================================
#if ENABLE_COMPOSITE
void crt_composite_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 c = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float px = ReShade::PixelSize.x;

    // Extract luma
    float luma = dot(c, float3(0.299, 0.587, 0.114));

    // Chroma blur: box blur colour channels horizontally
    if (crt_composite_chroma_blur > 0.001)
    {
        // Box blur colour channels with width proportional to chroma_blur.
        // No triangle weighting -- flat box gives stronger, more visible bleed.
        int   taps       = int(ceil(crt_composite_chroma_blur * 2.0));
        float3 chroma_sum = 0.0;
        for (int i = -taps; i <= taps; i++)
        {
            float2 uv = texcoord + float2((float(i) + crt_composite_chroma_phase) * px, 0.0);
            chroma_sum += tex2D(ReShade::BackBuffer, uv).rgb;
        }
        float3 c_blurred = chroma_sum / float(2*taps + 1);

        // Correct luma-preserving recombine:
        // Scale blurred RGB so its luma matches original luma exactly.
        float luma_blurred = dot(c_blurred, float3(0.299, 0.587, 0.114));
        float luma_ratio   = (luma_blurred > 0.0001) ? luma / luma_blurred : 1.0;
        c = c_blurred * luma_ratio;
    }

    // Luma sharpness boost: unsharp mask on luma channel, sampled from c (post-blur)
    if (crt_composite_luma_sharpen > 0.001)
    {
        float3 left  = tex2D(ReShade::BackBuffer, texcoord - float2(px * 2.0, 0.0)).rgb;
        float3 right = tex2D(ReShade::BackBuffer, texcoord + float2(px * 2.0, 0.0)).rgb;
        float luma_l = dot(left,  float3(0.299, 0.587, 0.114));
        float luma_r = dot(right, float3(0.299, 0.587, 0.114));
        // Apply sharpening as a luminance scale to preserve hue
        float edge      = luma - 0.5*(luma_l + luma_r);
        float luma_sharp = max(luma + edge * crt_composite_luma_sharpen, 0.0001);
        c *= luma_sharp / max(luma, 0.0001);
        c  = max(c, 0.0);
    }

    color = float4(c, 1.0);
}
#endif // ENABLE_COMPOSITE

// ============================================================
// Screen reflection pass -- faint blurred self-reflection at screen edges
// Simulates thick CRT glass internal reflection: bright content near edges
// bounces back faintly, fading toward screen centre.
// ============================================================
#if ENABLE_SCREEN_REFLECT
void crt_screen_reflect_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 c = tex2D(ReShade::BackBuffer, texcoord).rgb;
    if (crt_reflect_strength > 0.001)
    {
        // Edge mask: distance from screen centre, stronger at edges.
        // Uses distance from 0.5 in each axis, raised to power for falloff shape.
        float2 edge_dist = abs(texcoord - 0.5) * 2.0; // 0 at centre, 1 at edge
        float  edge_mask = pow(max(edge_dist.x, edge_dist.y), crt_reflect_fade);
        edge_mask = saturate(edge_mask);

        // Sample from wide glow texture as reflection source -- already blurred.
        // Gamma compresses to concentrate on bright content.
        float3 reflect_src = tex2D(crt_glow_wide_v_sampler, texcoord).rgb;
        reflect_src = pow(max(reflect_src, 0.0), crt_reflect_gamma);

        // Additive composite gated to screen edges
        c += reflect_src * crt_reflect_strength * edge_mask;
    }
    color = float4(c, 1.0);
}
#endif // ENABLE_SCREEN_REFLECT

// ============================================================
// Tube diffuse pass -- ambient phosphor scatter glow through CRT glass
// ============================================================
#if ENABLE_TUBE_DIFFUSE
void crt_tube_diffuse_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 c = tex2D(ReShade::BackBuffer, texcoord).rgb;
    if (crt_tube_diffuse_strength > 0.001)
    {
        // Sample from the wide glow texture -- already heavily blurred.
        // Apply gamma to concentrate the effect on brighter content,
        // then composite additively at low strength.
        float3 diffuse = tex2D(crt_glow_wide_v_sampler, texcoord).rgb;
        diffuse = pow(max(diffuse, 0.0), crt_tube_diffuse_gamma);
        c += diffuse * crt_tube_diffuse_strength;
    }
    color = float4(c, 1.0);
}
#endif // ENABLE_TUBE_DIFFUSE

// ============================================================
// Noise floor pass -- fixed-pattern thermal noise, independent of interference
// ============================================================
#if ENABLE_NOISE_FLOOR
void crt_noise_floor_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 c = tex2D(ReShade::BackBuffer, texcoord).rgb;
    if (crt_noise_floor > 0.001)
    {
        uint2 noise_px   = uint2(texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT)
                           / max(crt_noise_floor_scale, 1.0));
        // Slow temporal variation: changes every 4 frames so it drifts
        // rather than being static, but slower than film grain (every frame)
        uint  frame_slow = (FRAMECOUNT / 4u) * 0x9E3779B9u;
        uint  noise_seed = noise_px.x * 1973u + noise_px.y * 9277u + frame_slow;
        float noise_val  = (grain_unorm1(grain_uhash(noise_seed)) - 0.5) * 2.0;
        float luma_n    = dot(c, float3(0.299, 0.587, 0.114));
        float dark_gate = saturate(1.0 - luma_n * 2.0); // fades above ~50% luma
        c = saturate(c + noise_val * crt_noise_floor * dark_gate);
    }
    color = float4(c, 1.0);
}
#endif // ENABLE_NOISE_FLOOR

// ============================================================
// Interference pass -- all signal-level effects as post-process
// Applied to the final image after all CRT rendering is complete.
// Effects in order: accumulate, wiggle, hum bars, rolling scanlines, ghost
// ============================================================
#if ENABLE_INTERFERENCE
void crt_accum_store_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    color = tex2D(ReShade::BackBuffer, texcoord);
}

void crt_interference_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    // -- Accumulate modulation (phosphor afterglow, NewPixie approach) --
    // max(prev*modulate, current*0.96): bright content trails across frames.
    float2 src_uv = texcoord;
    if (crt_accum_modulate > 0.001)
    {
        float4 prev    = tex2D(crt_accum_samp, texcoord) * crt_accum_modulate;
        float4 current = tex2D(ReShade::BackBuffer, texcoord) * 0.96;
        color = max(prev, current);
    }
    else
    {
        color = tex2D(ReShade::BackBuffer, texcoord);
    }

    float3 c = color.rgb;

    // -- H-sync instability: probabilistic per-row horizontal displacement --
    // Fires on random rows with probability crt_hsync_rate per row per frame.
    // Displacement magnitude varies per row. Stronger near top of screen.
    if (crt_hsync_strength > 0.001)
    {
        uint row       = uint(texcoord.y * float(BUFFER_HEIGHT));
        // Fast per-row per-frame hash -- changes every frame for probabilistic firing
        uint hsync_seed = row * 3761u + FRAMECOUNT * 0x45D9F3Bu;
        float rand_val  = grain_unorm1(grain_uhash(hsync_seed));
        // Fire if random value below rate threshold
        if (rand_val < crt_hsync_rate)
        {
            // Displacement amount: second hash for magnitude + sign
            uint  mag_seed  = row * 9277u + FRAMECOUNT * 0x1B873593u;
            float disp      = (grain_unorm1(grain_uhash(mag_seed)) - 0.5) * 2.0;
            // Slightly stronger near top (sync lock weaker at frame start)
            float top_bias  = 1.0 + (1.0 - texcoord.y) * 0.5;
            // Resolution-scaled
            float hs_scale  = 1080.0 / float(BUFFER_WIDTH);
            float2 hs_uv    = float2(texcoord.x + disp * crt_hsync_strength * top_bias * hs_scale,
                                     texcoord.y);
            c = tex2D(ReShade::BackBuffer, hs_uv).rgb;
        }
    }

    // -- Wiggle: horizontal UV displacement (NewPixie triple-sine) --
    // Post-process UV warp on the already-rendered image.
    if (crt_wiggle_strength > 0.0001)
    {
        float t_wig = (float(FRAMECOUNT) - 849.0*floor(float(FRAMECOUNT)/849.0)) * 36.0 * crt_wiggle_speed;
        float wig   = sin(0.1*t_wig  + texcoord.y*13.0)
                    * sin(0.23*t_wig + texcoord.y*19.0)
                    * sin(0.3 + 0.11*t_wig + texcoord.y*23.0);
        // Scale by reference resolution: same strength = same pixel displacement at any res
        float wig_scale = 1080.0 / float(BUFFER_HEIGHT);
        float2 warp_uv = float2(texcoord.x + wig * crt_wiggle_strength * wig_scale, texcoord.y);
        c = tex2D(ReShade::BackBuffer, warp_uv).rgb;
    }

    // -- Magnetic interference: radial hue rotation around source point --
    if (crt_magnetic_strength > 0.001)
    {
        // Distance from magnetic source, aspect-corrected
        float ar = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
        float2 src = float2(crt_magnetic_x, crt_magnetic_y);
        float2 delta = (texcoord - src) * float2(ar, 1.0);
        float dist = length(delta);

        // Animated ring phase: slow outward drift
        float t_mag = CRT_TIMER * 0.001 * crt_magnetic_speed;
        // Ring pattern: sin of distance creates concentric rings,
        // phase offset by time makes them drift outward
        float ring_phase = dist / max(crt_magnetic_radius, 0.001) * 6.2832 - t_mag;
        float ring = sin(ring_phase);

        // Hue rotation amount: stronger near source, modulated by ring pattern
        float dist_gate = exp(-dist / max(crt_magnetic_radius, 0.001));
        float angle = ring * dist_gate * crt_magnetic_strength * 3.14159;

        c = hue_rotate(c, angle);
    }

    // -- Dot crawl: NTSC colour subcarrier interference at luma-chroma boundaries --
    // Animated diagonal pattern at colour edges, characteristic of composite video.
    if (crt_dot_crawl > 0.001)
    {
        // Phase advances ~3.58 cycles per frame (NTSC subcarrier relationship)
        float phase = float(FRAMECOUNT) * 0.279; // ~pi/2 * 3.58/4 approximation
        float2 fc_pos = texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT);
        // Chequered subcarrier pattern: alternates sign with pixel position and time
        float subcarrier = sin(phase + (floor(fc_pos.x) + floor(fc_pos.y)) * 3.14159);
        // Gate to colour edges only -- measure local colour variation
        float2 px = ReShade::PixelSize;
        float3 left  = tex2D(ReShade::BackBuffer, texcoord - float2(px.x, 0)).rgb;
        float3 right = tex2D(ReShade::BackBuffer, texcoord + float2(px.x, 0)).rgb;
        float chroma_edge = length((left - right) - dot(left - right, float3(0.299,0.587,0.114)));
        float gate = saturate(chroma_edge * 8.0);
        // Add the subcarrier pattern modulated by the colour edge strength
        c += subcarrier * crt_dot_crawl * gate;
        c = max(c, 0.0);
    }

    // -- Hum bars: AC mains interference scrolling brightness gradient --
    if (abs(crt_hum_intensity) > 0.001)
    {
        float hum_scroll = frac(texcoord.y + float(FRAMECOUNT) / crt_hum_speed);
        float hum_mult = (crt_hum_intensity >= 0.0)
            ? (1.0 - crt_hum_intensity) + crt_hum_intensity * hum_scroll
            : (1.0 + crt_hum_intensity) + crt_hum_intensity * (hum_scroll - 1.0);
        c *= hum_mult;
    }

    // -- Scanline jitter: per-scanline vertical displacement --
    if (crt_scanline_jitter > 0.001)
    {
        uint row      = uint(texcoord.y * float(BUFFER_HEIGHT));
        uint t_slow   = (FRAMECOUNT / 3u) * 0x9E3779B9u;
        uint jit_seed = row * 1447u + t_slow;
        float jitter  = (grain_unorm1(grain_uhash(jit_seed)) - 0.5) * 2.0;
        // Slider is in pixel units -- convert to UV
        float2 jit_uv = float2(texcoord.x, texcoord.y + jitter * crt_scanline_jitter * ReShade::PixelSize.y);
        c = tex2D(ReShade::BackBuffer, jit_uv).rgb;
    }

    // -- Rolling scanlines: sync instability at screen-resolution frequency --
    // Matches NewPixie scanroll. crt_flicker_strength = speed (0 = disabled/no movement).
    // When speed > 0, time advances and scanlines scroll. No darkening when disabled.
    if (crt_flicker_strength > 0.0001)
    {
        float t_sc  = (float(FRAMECOUNT) - 640.0*floor(float(FRAMECOUNT)/640.0))
                    * crt_flicker_strength;
        // sin oscillates around 0: at t=0, sin=0, scans=0.35+0=0.35 -> darkening.
        // Shift by pi/2 so at t=0 scans=0.35+0.18=0.53 -> minimal darkening at start.
        // Use abs() so scans never goes below 0.35 -- avoids systematic darkening.
        float scans = 0.35 + 0.18 * abs(sin(6.0*t_sc - texcoord.y * float(BUFFER_HEIGHT) * 1.5));
        c *= pow(scans / 0.53, 0.9); // normalise so peak = 1.0
    }

    // -- Ghost image: RF reflection/antenna delay --
    // Matches NewPixie exactly: fixed small displacement + tiny animated wobble.
    // Base offsets are small (~1-2%) so ghost appears close to source, not far away.
    // time uses mod(FRAMECOUNT,849)*36 same as wiggle -- slow enough to be visible.
    if (crt_ghost_strength > 0.0001)
    {
        float t_g = (float(FRAMECOUNT) - 849.0*floor(float(FRAMECOUNT)/849.0))
                  * 36.0 * crt_ghost_speed;
        // Fixed base offset (small, close to source) + tiny animated wobble
        // Scale offsets by resolution: NewPixie values tuned for 1080p.
        // At 4K the same UV offset covers twice as many pixels, so scale down.
        float ghost_res_scale = 1080.0 / float(BUFFER_HEIGHT);
        float2 r_uv = texcoord + (float2(-0.014, -0.027)*0.85
                    + 0.007*float2(0.35*sin(1.0/7.0 + 15.0*texcoord.y + 0.9*t_g),
                                   0.35*sin(2.0/7.0 + 10.0*texcoord.y + 1.37*t_g))
                    + float2(0.001, 0.001)) * ghost_res_scale;
        float2 g_uv = texcoord + (float2(-0.019, -0.020)*0.85
                    + 0.007*float2(0.35*cos(1.0/9.0 + 15.0*texcoord.y + 0.5*t_g),
                                   0.35*sin(2.0/9.0 + 10.0*texcoord.y + 1.50*t_g))
                    + float2(0.000, -0.002)) * ghost_res_scale;
        float2 b_uv = texcoord + (float2(-0.017, -0.003)*0.85
                    + 0.007*float2(0.35*sin(2.0/3.0 + 15.0*texcoord.y + 0.7*t_g),
                                   0.35*cos(2.0/3.0 + 10.0*texcoord.y + 1.63*t_g))
                    + float2(-0.002, 0.000)) * ghost_res_scale;
        float3 ghost_r = tex2D(ReShade::BackBuffer, r_uv).rgb * float3(0.5, 0.25, 0.25);
        float3 ghost_g = tex2D(ReShade::BackBuffer, g_uv).rgb * float3(0.25, 0.5, 0.25);
        float3 ghost_b = tex2D(ReShade::BackBuffer, b_uv).rgb * float3(0.25, 0.25, 0.5);
        float luma_i = dot(c, float3(0.299, 0.587, 0.114));
        float i = (1.0 - luma_i*luma_i) * 0.85 + 0.15;
        float ghs = crt_ghost_strength;
        c += (ghs*(1.0-0.299)) * pow(saturate(3.0*ghost_r), 2.0) * i;
        c += (ghs*(1.0-0.587)) * pow(saturate(3.0*ghost_g), 2.0) * i;
        c += (ghs*(1.0-0.114)) * pow(saturate(3.0*ghost_b), 2.0) * i;
    }

    color = float4(c, 1.0);
}
#endif // ENABLE_INTERFERENCE

// ============================================================
// Light Warp pass
// ============================================================
#if ENABLE_LIGHT_WARP
void crt_light_warp_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    if (abs(crt_warp_strength) < 0.001 && abs(crt_pin_phase) < 0.001 && abs(crt_pin_amp) < 0.001)
    {
        color = tex2D(ReShade::BackBuffer, texcoord);
        return;
    }
    float ar   = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
    float2 uv  = texcoord - 0.5;
    uv.x      *= ar;

    // Radial barrel/pincushion
    float  r2  = dot(uv, uv);
    uv        *= 1.0 + crt_warp_strength * r2;

    // Pin phase: horizontal linearity varies with vertical position (Megatron).
    uv.x      *= 1.0 + crt_pin_phase * (uv.y / max(0.5 * ar, 0.001));
    // Pin amp: vertical linearity varies with horizontal position (complement).
    uv.y      *= 1.0 + crt_pin_amp   * (uv.x / max(0.5, 0.001));

    uv.x      /= ar;
    uv        += 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        color = float4(crt_warp_border_colour, 1.0);
    else
        color = tex2D(ReShade::BackBuffer, uv);
}
#endif



// ============================================================
// Corner rounding pass
// Based on Guest Advanced corner() function -- multiplier approach
// that darkens edges/corners rather than filling with a flat colour.
// Three parameters: corner size, border shadow, intensity power curve.
// ============================================================
#if ENABLE_CORNER_ROUND
float crt_corner_mask(float2 texcoord)
{
    float ar  = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
    float2 aspect = float2(1.0, ar);

    // Remap texcoord to [0,1] centred, then take absolute value -> [0, 0.5]
    float2 pos = abs(2.0 * (texcoord - 0.5));

    // Border: adds uniform edge shadow on all four sides
    float b = crt_corner_border * 0.05 + 0.0005;
    // Aspect-correct the vertical border contribution
    pos.y = pos.y + b * (aspect.y - 1.0);

    // Corner radius: must be at least as large as border to avoid artefacts
    float2 crn = max(crt_corner_size.xx, 2.0 * b + 0.0015);

    // Distance into corner region (aspect corrected)
    float2 crp = max(pos - (1.0 - crn * aspect), 0.0) / aspect;
    float  cd  = sqrt(dot(crp, crp));

    // Blend the corner geometry into the position
    pos = max(pos, 1.0 - crn + cd);

    // Smooth mask: 1.0 inside, 0.0 outside, with border transition
    float res = lerp(1.0, 0.0, smoothstep(1.0 - b, 1.0, sqrt(max(pos.x, pos.y))));

    // Power curve controls sharpness of the edge/corner
    return pow(res, crt_corner_intensity);
}

void crt_corner_round_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    float3 screen = tex2D(ReShade::BackBuffer, texcoord).rgb;

    if (crt_corner_size < 0.001 && crt_corner_border < 0.001)
    {
        color = float4(screen, 1.0);
        return;
    }

    float mask = crt_corner_mask(texcoord);
    // Multiply the image by the mask -- darkens edges/corners, black outside
    color = float4(screen * mask, 1.0);
}
#endif

// ============================================================

technique CRT_Standalone <
    ui_label = "CRT Standalone";
    ui_tooltip = "Pre-blur (H+V) + mask + Megatron beam + gamma + brightboost + glow + grain.";
>
{
    #if PIPELINE >= 1
    pass SoopBefore
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_soop_before_PS;
    }
    #endif
    #if ENABLE_PREBLUR
    pass PreBlurH
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_preblur_h_PS;
        RenderTarget = crt_preblur_h_tex;
    }
    pass PreBlurV
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_preblur_v_PS;
        RenderTarget = crt_preblur_v_tex;
    }
    #endif
    #if ENABLE_HALATION
    pass HalationH
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_halation_PS;
        RenderTarget = crt_halation_tex;
    }
    pass HalationV
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_halation_v_PS;
        RenderTarget = crt_halation_v_tex;
    }
    #endif
    pass GlowH
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_glow_h_PS;
        RenderTarget = crt_glow_tex;
    }
    pass GlowV
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_glow_v_PS;
        RenderTarget = crt_glow_v_tex;
    }
    pass GlowWideH
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_glow_wide_h_PS;
        RenderTarget = crt_glow_wide_tex;
    }
    pass GlowWideV
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_glow_wide_v_PS;
        RenderTarget = crt_glow_wide_v_tex;
    }
    pass MainCRT
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_main_PS;
    }
    #if ENABLE_SHARPEN
    pass Sharpen
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_sharpen_PS;
    }
    #endif
    #if ENABLE_SCANLINE_SOFTEN
    pass ScanlineSoften
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_soften_PS;
    }
    #endif
    #if ENABLE_MOTION_SHARPEN
    pass MotionSharpen
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_motion_sharpen_PS;
    }
    #endif
    #if ENABLE_PERSISTENCE
    pass Persistence
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_persistence_PS;
    }
    pass PersistenceStore
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_persistence_store_PS;
        RenderTarget = crt_persistence_tex;
    }
    #endif
    #if ENABLE_EDGE_BLUR
    pass EdgeBlur
    {
        // Writes directly to backbuffer -- no intermediate texture
        VertexShader = PostProcessVS;
        PixelShader  = crt_edge_blur_PS;
    }
    #endif
    #if ENABLE_GRAIN
    pass GrainMerged
    {
        // Dual output: clean snapshot + grain delta
        VertexShader  = PostProcessVS;
        PixelShader   = crt_grain_merged_PS;
        RenderTarget0 = crt_pregrain_tex;
        RenderTarget1 = crt_grain_raw_tex;
    }
    pass GrainDiffuse
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_grain_diffuse_PS;
    }
    #endif // ENABLE_GRAIN
    #if ENABLE_NOISE_FLOOR
    pass NoiseFloor
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_noise_floor_PS;
    }
    #endif
    #if ENABLE_DECAY
    // Merged store: raw capture + prev1 update in one dual-output pass.
    // Saves one full-resolution pass vs the original three separate passes.
    pass PhosphorDecayStoreRawPrev1
    {
        VertexShader  = PostProcessVS;
        PixelShader   = crt_decay_store_PS;
        RenderTarget0 = crt_decay_raw_tex;
        RenderTarget1 = crt_decay_prev1_tex;
    }
    pass PhosphorDecayPrev2Store
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_decay_prev2_store_PS;
        RenderTarget = crt_decay_prev2_tex;
    }
    pass PhosphorDecayPhaseStore
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_decay_phase_store_PS;
        RenderTarget = crt_decay_phase_tex;
    }
    pass PhosphorDecay
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_decay_PS;
    }
    // Auto-resync luminance monitors (run after decay, before next phase store)
    pass LumaMonitorLitCopy
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_decay_luma_lit_copy_PS;
        RenderTarget = crt_decay_luma_lit_prev_tex;
    }
    pass LumaMonitorDarkCopy
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_decay_luma_dark_copy_PS;
        RenderTarget = crt_decay_luma_dark_prev_tex;
    }
    pass LumaMonitorLit
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_decay_luma_lit_PS;
        RenderTarget = crt_decay_luma_lit_tex;
    }
    pass LumaMonitorDark
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_decay_luma_dark_PS;
        RenderTarget = crt_decay_luma_dark_tex;
    }
    #endif
    #if PIPELINE >= 1
    pass SoopAfter
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_soop_after_PS;
    }
    #endif
    #if ENABLE_SCREEN_REFLECT
    pass ScreenReflect
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_screen_reflect_PS;
    }
    #endif
    #if ENABLE_TUBE_DIFFUSE
    pass TubeDiffuse
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_tube_diffuse_PS;
    }
    #endif
    #if ENABLE_INTERFERENCE
    pass Interference
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_interference_PS;
    }
    pass AccumStore
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_accum_store_PS;
        RenderTarget = crt_accum_tex;
    }
    #endif
    #if ENABLE_LIGHT_WARP
    pass LightWarp
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_light_warp_PS;
    }
    #endif

    #if ENABLE_CORNER_ROUND
    pass CornerRound
    {
        VertexShader = PostProcessVS;
        PixelShader  = crt_corner_round_PS;
    }
    #endif
}
