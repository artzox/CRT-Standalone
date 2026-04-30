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
#ifndef GLOW_RESOLUTION
    #define GLOW_RESOLUTION 2
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
uniform float crt_persistence_strength <
    ui_type = "drag"; ui_label = "Persistence Strength";
    ui_category = "Phosphor Persistence";
    ui_tooltip = "Simulates phosphor decay within a single frame by blending a\n"
                 "downward-offset copy of the image. Mimics the CRT beam sweep\n"
                 "leaving a fading trail below each scanline.\n"
                 "Keep very low -- 0.05-0.15 for subtle CRT character.\n"
                 "Higher values look like ghosting.\n"
                 "Set ENABLE_PERSISTENCE=0 to remove pass entirely.";
    ui_min = 0.0; ui_max = 0.5; ui_step = 0.005;
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

uniform float crt_beam_min_sigma <
    ui_type = "drag"; ui_label = "Beam Sigma (Dark pixels)";
    ui_category = "Scanlines";
    ui_tooltip = "Used with ENABLE_BEAM_MODULATION=1.";
    ui_min = 0.05; ui_max = 2.0; ui_step = 0.01;
> = 0.3;
uniform float crt_beam_max_sigma <
    ui_type = "drag"; ui_label = "Beam Sigma (Bright pixels)";
    ui_category = "Scanlines";
    ui_min = 0.05; ui_max = 2.0; ui_step = 0.01;
> = 0.6;
uniform float crt_scanline_sigma <
    ui_type = "drag"; ui_label = "Beam Sigma (Fixed, BEAM_MODULATION=0)";
    ui_category = "Scanlines";
    ui_min = 0.1; ui_max = 2.0; ui_step = 0.05;
> = 0.4;

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
    ui_type = "drag"; ui_label = "Vignette HDR Protection Threshold";
    ui_category = "Vignette";
    ui_tooltip = "Pixels brighter than this are progressively protected from vignetting.\n"
                 "0.5 = protect upper midtones and highlights.\n"
                 "0.8 = only protect bright HDR highlights.\n"
                 "1.0 = no protection (affects everything equally).\n"
                 "Prevents vignette from crushing HDR content at screen edges.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.5;
#endif // ENABLE_VIGNETTE

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

// Analog film grain parameters (compute shader path only)

uniform uint  FRAMECOUNT < source = "framecount"; >;
uniform float CRT_TIMER     < source = "timer"; >;       // milliseconds since start
uniform float CRT_FRAMETIME < source = "frametime"; >;   // actual ms elapsed this frame
#endif // ENABLE_GRAIN

// ============================================================
// Uniforms -- Phosphor Decay
// Two methods selectable at runtime:
//   0 = Fibonacci (CRT Dusha-style, uniform darkening)
//   1 = Variable MPRT (Blur Busters, brightness-preserving)
// Set ENABLE_DECAY=1 to enable. Best at 120fps+.
// ============================================================

#if ENABLE_DECAY

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
texture2D crt_decay_luma_lit_tex  < pooled = false; > { Width=1; Height=1; Format=R16F; };
texture2D crt_decay_luma_dark_tex < pooled = false; > { Width=1; Height=1; Format=R16F; };
sampler2D crt_decay_luma_lit_sampler  { Texture=crt_decay_luma_lit_tex;  MipFilter=NONE; MinFilter=POINT; MagFilter=POINT; };
sampler2D crt_decay_luma_dark_sampler { Texture=crt_decay_luma_dark_tex; MipFilter=NONE; MinFilter=POINT; MagFilter=POINT; };

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
// Diffusion blurs this delta then adds it to the clean image
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
        #else
        // Lanczos for centre tap (sharpest warp reconstruction).
        // Bilinear for offset taps -- they are Gaussian-weighted anyway,
        // so the blur dominates and Lanczos per-tap would be wasteful.
        float  px_bb = ReShade::PixelSize.x;
        float2 uv_hal = geom_warp(texcoord) + float2(float(i)*px_bb, 0.0);
        float3 s = (i == 0)
            ? geom_sample_lanczos2(ReShade::BackBuffer, geom_warp(texcoord))
            : tex2D(ReShade::BackBuffer, uv_hal).rgb;
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
    float3 result = 0.0;
    float  wsum   = 0.0;
    // Glow samples from preblur (at PREBLUR_RESOLUTION) or backbuffer (full-res).
    // Scale pixel step to match the preblur source resolution.
    float  px     = ReShade::PixelSize.x * float(PREBLUR_RESOLUTION);
    // Clamp radius to compile-time constant so loop unrolls fully
    int    radius = min(int(crt_glow_h_radius), GLOW_H_MAX_RADIUS);
    float  sigma  = crt_glow_sigma * crt_glow_h_radius * 0.25;

    [unroll]
    for (int i = -GLOW_H_MAX_RADIUS; i <= GLOW_H_MAX_RADIUS; i++)
    {
        float  w = (abs(i) <= radius) ? gauss(float(i), sigma) : 0.0;
        #if ENABLE_PREBLUR
        float3 s = tex2D(crt_preblur_v_sampler, texcoord + float2(float(i)*px, 0.0)).rgb;
        #else
        // Lanczos for centre tap, bilinear for offsets
        float2 uv_glow = geom_warp(texcoord) + float2(float(i)*px, 0.0);
        float3 s = (i == 0)
            ? geom_sample_lanczos2(ReShade::BackBuffer, geom_warp(texcoord))
            : tex2D(ReShade::BackBuffer, uv_glow).rgb;
        #endif
        float lum = dot(s, float3(0.2126, 0.7152, 0.0722));
        // Soft knee: at knee=0 identical to original hard threshold.
        // At knee>0, smoothstep fades glow in over a range of knee width
        // above the threshold rather than switching on abruptly.
        float gate;
        if (crt_glow_knee < 0.001)
            gate = float(lum > crt_glow_threshold);
        else
            { float t = saturate((lum - crt_glow_threshold) / crt_glow_knee);
              gate = t * t * (3.0 - 2.0 * t); }
        s = max(s - crt_glow_threshold, 0.0) * lum * gate;
        result += s * w;
        wsum   += w;
    }

    float3 g = result / max(wsum, 1e-5);
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
    float2 uv_r = texcoord + float2(0.0, crt_convergence_r * ReShade::PixelSize.y) + ca_r;
    float2 uv_g = texcoord + float2(0.0, crt_convergence_g * ReShade::PixelSize.y);
    float2 uv_b = texcoord + float2(0.0, crt_convergence_b * ReShade::PixelSize.y) + ca_b;
    #else
    float2 uv_r = texcoord + ca_r;
    float2 uv_g = texcoord;
    float2 uv_b = texcoord + ca_b;
    #endif

    #if ENABLE_PREBLUR
    float3 c = float3(
        tex2D(crt_preblur_v_sampler, uv_r).r,
        tex2D(crt_preblur_v_sampler, uv_g).g,
        tex2D(crt_preblur_v_sampler, uv_b).b);
    #else
    float3 c = float3(
        geom_sample_lanczos2(ReShade::BackBuffer, geom_warp(uv_r)).r,
        geom_sample_lanczos2(ReShade::BackBuffer, geom_warp(uv_g)).g,
        geom_sample_lanczos2(ReShade::BackBuffer, geom_warp(uv_b)).b);
    #endif

    // -- Phosphor profile correction (before BCS) --
    #if ENABLE_PHOSPHOR
    if (crt_phosphor_strength > 0.001)
        c = apply_phosphor(c);
    #endif

    // -- Colour temperature --
    if (abs(crt_colour_temp) > 0.001)
        c = apply_colour_temp(c, crt_colour_temp);

    // -- BCS (Megatron Bezier in Yxy, no washout) --
    if (abs(crt_brightness)>0.001 || abs(crt_contrast)>0.001 || abs(crt_saturation)>0.001)
        c = apply_bcs(c, crt_brightness, crt_contrast, crt_saturation);

    // -- CRT gamma decode --
    float3 c_lin = crt_to_linear(c);

    // -- Aperture grille mask --
    #if ENABLE_MASK
        // Apply horizontal phase shift + orbit to mask
        float2 fc_mask = fc + float2(phase_h + orbit_h, 0.0);
        float  mask_pixel_luma = dot(max(c, 0.0), float3(0.2126, 0.7152, 0.0722));
        float3 mask = crt_mask_apply(fc_mask, crt_triad_width, crt_mask_strength,
                                    crt_phosphor_sharpness, crt_phosphor_colour,
                                    crt_mask_type, crt_slot_mask_strength,
                                    crt_mask_offset_x, crt_mask_offset_y, fc,
                                    mask_pixel_luma);
        c_lin = c_lin * mask * crt_mask_boost;
    #endif

    // -- Scanlines with sub-pixel AA --
    // No vertical burn-in offset applied -- any vertical shift changes brightness
    // because frac() maps non-linearly to the gaussian beam profile.
    // Horizontal mask shift (phase_h + orbit_h) handles burn-in protection instead.
    float scanline_y = fc.y;
    float f  = frac(scanline_y / crt_scanline_width) - 0.5;
    float fw = fwidth(scanline_y / crt_scanline_width);
    float fa = f - fw * 0.5;
    float fb = f + fw * 0.5;
    float da = abs(fa) * 2.0;
    float db = abs(fb) * 2.0;

    #if ENABLE_BEAM_MODULATION
        float r_sigma = lerp(crt_beam_min_sigma, crt_beam_max_sigma, saturate(c_lin.r));
        float g_sigma = lerp(crt_beam_min_sigma, crt_beam_max_sigma, saturate(c_lin.g));
        float b_sigma = lerp(crt_beam_min_sigma, crt_beam_max_sigma, saturate(c_lin.b));
        float beam_r = 0.5*(megatron_scanline(c_lin.r,da,crt_r_scanline_min,crt_r_scanline_max,crt_r_scanline_attack)*gauss(fa,r_sigma)
                           +megatron_scanline(c_lin.r,db,crt_r_scanline_min,crt_r_scanline_max,crt_r_scanline_attack)*gauss(fb,r_sigma));
        float beam_g = 0.5*(megatron_scanline(c_lin.g,da,crt_g_scanline_min,crt_g_scanline_max,crt_g_scanline_attack)*gauss(fa,g_sigma)
                           +megatron_scanline(c_lin.g,db,crt_g_scanline_min,crt_g_scanline_max,crt_g_scanline_attack)*gauss(fb,g_sigma));
        float beam_b = 0.5*(megatron_scanline(c_lin.b,da,crt_b_scanline_min,crt_b_scanline_max,crt_b_scanline_attack)*gauss(fa,b_sigma)
                           +megatron_scanline(c_lin.b,db,crt_b_scanline_min,crt_b_scanline_max,crt_b_scanline_attack)*gauss(fb,b_sigma));
    #else
        float beam_r = 0.5*(megatron_scanline(c_lin.r,da,crt_r_scanline_min,crt_r_scanline_max,crt_r_scanline_attack)*gauss(fa,crt_scanline_sigma)
                           +megatron_scanline(c_lin.r,db,crt_r_scanline_min,crt_r_scanline_max,crt_r_scanline_attack)*gauss(fb,crt_scanline_sigma));
        float beam_g = 0.5*(megatron_scanline(c_lin.g,da,crt_g_scanline_min,crt_g_scanline_max,crt_g_scanline_attack)*gauss(fa,crt_scanline_sigma)
                           +megatron_scanline(c_lin.g,db,crt_g_scanline_min,crt_g_scanline_max,crt_g_scanline_attack)*gauss(fb,crt_scanline_sigma));
        float beam_b = 0.5*(megatron_scanline(c_lin.b,da,crt_b_scanline_min,crt_b_scanline_max,crt_b_scanline_attack)*gauss(fa,crt_scanline_sigma)
                           +megatron_scanline(c_lin.b,db,crt_b_scanline_min,crt_b_scanline_max,crt_b_scanline_attack)*gauss(fb,crt_scanline_sigma));
    #endif

    c_lin *= lerp(1.0, float3(beam_r, beam_g, beam_b), crt_scanline_strength);

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
        vig = lerp(1.0, vig, crt_vignette_strength);

        // HDR gate: fade vignette out for bright pixels
        float vig_luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        float vig_gate = 1.0 - saturate((vig_luma - crt_vignette_hdr_threshold) /
                                         max(1.0 - crt_vignette_hdr_threshold, 0.001));
        c *= lerp(1.0, vig, vig_gate);
    }
    #endif // ENABLE_VIGNETTE

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

    // -- Glow (combined H+V, precomputed in GlowV pass) --
    if (crt_glow_strength > 0.001)
    {
        float3 glow = tex2D(crt_glow_v_sampler, texcoord).rgb;
        c += crt_glow_strength * glow;
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

    // Blend in linear light -- gamma-correct lerp avoids brightness bias in shadows.
    float3 cur_lin   = glin(current);
    float3 above_lin = glin(above);
    float3 trail_lin = lerp(cur_lin, above_lin, crt_persistence_strength);
    float3 trail     = genc(max(trail_lin, 0.0));
    // Only ever adds light (like real phosphor persistence) -- never darkens
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
void crt_decay_luma_lit_PS(
    in  float4 position : SV_Position,
    in  float2 texcoord : TEXCOORD0,
    out float4 color    : SV_Target)
{
    int frames        = max(crt_decay_frames, 2);
    float4 phase_data = tex2D(crt_decay_phase_sampler, float2(0.5, 0.5));
    int    fic        = int(round(phase_data.r * 255.0)) % frames;
    float  prev       = tex2D(crt_decay_luma_lit_sampler, float2(0.5, 0.5)).r;
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
    float  prev       = tex2D(crt_decay_luma_dark_sampler, float2(0.5, 0.5)).r;
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

            out_color = c * factor;
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
}
