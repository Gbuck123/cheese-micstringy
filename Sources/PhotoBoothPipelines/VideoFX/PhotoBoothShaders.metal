// PhotoBoothShaders.metal
// Core compute shaders for photo booth effects:
//   - Passthrough
//   - Color Grading / LUT
//   - Vintage / Film Grain
//   - Gaussian Blur (horizontal + vertical separable)
//   - Vignette
//   - Glow / Bloom (threshold + combine)
//   - Overlay Compositing (alpha blend with animated sprite sheets)

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// MARK: - Common Utilities
// ============================================================================

/// Convert linear RGB to luminance (BT.709 weights).
inline float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

/// Clamp a float3 to [0, 1].
inline float3 saturate3(float3 c) {
    return clamp(c, float3(0.0), float3(1.0));
}

// ============================================================================
// MARK: - 1. Passthrough Kernel
// ============================================================================

kernel void passthrough(
    texture2d<float, access::read>  inTex  [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    outTex.write(inTex.read(gid), gid);
}

// ============================================================================
// MARK: - 2. Color Grading / 3D LUT Application
// ============================================================================

/// Uniforms for color grading.
struct ColorGradeUniforms {
    float intensity;  // 0..1 blend between original and graded
};

/// Apply a 3D LUT stored as a 2D strip texture.
/// The LUT is expected as a horizontal strip of N slices, each N x N pixels,
/// for a total LUT dimension of N. Common sizes: 32 (1024x32) or 64 (4096x64).
kernel void colorGradeLUT(
    texture2d<float, access::read>   inTex   [[texture(0)]],
    texture2d<float, access::write>  outTex  [[texture(1)]],
    texture2d<float, access::sample> lutTex  [[texture(2)]],
    constant ColorGradeUniforms &uniforms    [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float4 color = inTex.read(gid);

    // LUT dimensions.
    float lutSize = float(lutTex.get_height());  // e.g., 32 or 64
    float maxIndex = lutSize - 1.0;

    // Scale colour to LUT indices.
    float3 scaled = saturate3(color.rgb) * maxIndex;

    // Blue slice pair (for trilinear interpolation).
    float sliceZ    = floor(scaled.z);
    float nextSlice = min(sliceZ + 1.0, maxIndex);
    float fracZ     = scaled.z - sliceZ;

    // UV coordinates within each slice.
    float u0 = (sliceZ  * lutSize + scaled.x + 0.5) / (lutSize * lutSize);
    float u1 = (nextSlice * lutSize + scaled.x + 0.5) / (lutSize * lutSize);
    float v  = (scaled.y + 0.5) / lutSize;

    constexpr sampler lutSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 sample0 = lutTex.sample(lutSampler, float2(u0, v));
    float4 sample1 = lutTex.sample(lutSampler, float2(u1, v));

    float4 graded = mix(sample0, sample1, fracZ);
    graded = mix(color, graded, uniforms.intensity);
    graded.a = color.a;

    outTex.write(graded, gid);
}

// ============================================================================
// MARK: - 3. Vintage / Film Grain
// ============================================================================

struct VintageUniforms {
    float time;           // seconds, for animated grain
    float grainIntensity; // 0..1
    float sepiaStrength;  // 0..1
    float vignetteAmount; // 0..1 (mild vignette baked into vintage look)
    float fadeAmount;     // 0..1 lifted blacks
    float saturation;     // 0..1, <1 for desaturation
};

/// Pseudo-random hash for film grain.
inline float hash(float2 p, float seed) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33 + seed);
    return fract((p3.x + p3.y) * p3.z);
}

kernel void vintageFilmGrain(
    texture2d<float, access::read>  inTex   [[texture(0)]],
    texture2d<float, access::write> outTex  [[texture(1)]],
    constant VintageUniforms &u             [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float4 color = inTex.read(gid);
    float2 uv = float2(gid) / float2(outTex.get_width(), outTex.get_height());

    // --- Desaturation ---
    float lum = luminance(color.rgb);
    color.rgb = mix(float3(lum), color.rgb, u.saturation);

    // --- Sepia toning ---
    float3 sepia = float3(
        lum * 1.2,
        lum * 1.0,
        lum * 0.8
    );
    color.rgb = mix(color.rgb, sepia, u.sepiaStrength);

    // --- Lifted blacks (fade) ---
    color.rgb = mix(color.rgb, max(color.rgb, float3(u.fadeAmount)), u.fadeAmount);

    // --- Film grain ---
    float grain = hash(float2(gid), fract(u.time * 7.0)) * 2.0 - 1.0;
    color.rgb += grain * u.grainIntensity;

    // --- Subtle baked-in vignette ---
    float2 center = uv - 0.5;
    float dist = length(center) * 1.4142;
    float vignette = smoothstep(0.9, 0.4, dist);
    color.rgb *= mix(1.0, vignette, u.vignetteAmount);

    color.rgb = saturate3(color.rgb);
    outTex.write(color, gid);
}

// ============================================================================
// MARK: - 4. Gaussian Blur (Separable, Two-Pass)
// ============================================================================

struct BlurUniforms {
    int   radius;     // kernel radius in pixels (e.g., 5 → 11-tap)
    float sigma;      // gaussian sigma
    int   direction;  // 0 = horizontal, 1 = vertical
};

kernel void gaussianBlur(
    texture2d<float, access::read>  inTex  [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    constant BlurUniforms &u               [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    int w = int(inTex.get_width());
    int h = int(inTex.get_height());

    float4 accum  = float4(0.0);
    float  weight = 0.0;

    float invSigma2 = -0.5 / (u.sigma * u.sigma);

    for (int i = -u.radius; i <= u.radius; i++) {
        int2 coord;
        if (u.direction == 0) {
            coord = int2(clamp(int(gid.x) + i, 0, w - 1), int(gid.y));
        } else {
            coord = int2(int(gid.x), clamp(int(gid.y) + i, 0, h - 1));
        }

        float g = exp(float(i * i) * invSigma2);
        accum += inTex.read(uint2(coord)) * g;
        weight += g;
    }

    outTex.write(accum / weight, gid);
}

// ============================================================================
// MARK: - 5. Vignette
// ============================================================================

struct VignetteUniforms {
    float intensity;    // Overall strength 0..1
    float radius;       // Inner radius (start of falloff) 0..1
    float softness;     // Width of falloff region 0..1
    float roundness;    // 1.0 = circular, <1 = more oval
    packed_float3 color; // Vignette colour (usually black)
};

kernel void vignette(
    texture2d<float, access::read>  inTex  [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    constant VignetteUniforms &u           [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float4 color = inTex.read(gid);
    float2 uv = float2(gid) / float2(outTex.get_width(), outTex.get_height());

    float2 center = uv - 0.5;
    // Apply roundness: stretch x for oval vignettes.
    center.x *= mix(1.0, float(outTex.get_height()) / float(outTex.get_width()), u.roundness);

    float dist = length(center) * 2.0;
    float vig = 1.0 - smoothstep(u.radius, u.radius + u.softness, dist);

    float3 vigColor = float3(u.color);
    color.rgb = mix(vigColor, color.rgb, mix(1.0, vig, u.intensity));

    outTex.write(color, gid);
}

// ============================================================================
// MARK: - 6. Glow / Bloom
// ============================================================================

// Pass 1: Brightness threshold — extract bright areas.
struct BloomThresholdUniforms {
    float threshold;   // luminance cutoff (e.g., 0.7)
    float softKnee;    // soft transition width
};

kernel void bloomThreshold(
    texture2d<float, access::read>  inTex  [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    constant BloomThresholdUniforms &u     [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float4 color = inTex.read(gid);
    float lum = luminance(color.rgb);

    float knee = u.threshold * u.softKnee;
    float soft = lum - u.threshold + knee;
    soft = clamp(soft, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-6);

    float contribution = max(soft, lum - u.threshold);
    contribution /= max(lum, 1e-6);

    outTex.write(float4(color.rgb * max(contribution, 0.0), color.a), gid);
}

// Pass 3: Combine original + blurred bloom.
struct BloomCombineUniforms {
    float intensity;   // bloom strength
};

kernel void bloomCombine(
    texture2d<float, access::read>  originalTex  [[texture(0)]],
    texture2d<float, access::write> outTex       [[texture(1)]],
    texture2d<float, access::read>  bloomTex     [[texture(2)]],
    constant BloomCombineUniforms &u             [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float4 original = originalTex.read(gid);

    // The bloom texture may be smaller (downsampled); read with clamped coordinates.
    uint2 bloomCoord = uint2(
        clamp(gid.x * bloomTex.get_width()  / outTex.get_width(),  0u, bloomTex.get_width()  - 1),
        clamp(gid.y * bloomTex.get_height() / outTex.get_height(), 0u, bloomTex.get_height() - 1)
    );
    float4 bloom = bloomTex.read(bloomCoord);

    float4 result = original + bloom * u.intensity;
    result.a = original.a;
    outTex.write(result, gid);
}

// ============================================================================
// MARK: - 7. Overlay Compositing (Alpha Blend + Sprite Sheet)
// ============================================================================

struct OverlayUniforms {
    float opacity;         // Overall overlay opacity 0..1
    int   spriteColumns;   // Number of columns in sprite sheet (1 for static)
    int   spriteRows;      // Number of rows in sprite sheet (1 for static)
    int   currentFrame;    // Current animation frame index
    int   blendMode;       // 0 = normal, 1 = multiply, 2 = screen, 3 = overlay
};

kernel void overlayComposite(
    texture2d<float, access::read>   inTex      [[texture(0)]],
    texture2d<float, access::write>  outTex     [[texture(1)]],
    texture2d<float, access::sample> overlayTex [[texture(2)]],
    constant OverlayUniforms &u                 [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float4 base = inTex.read(gid);

    // Compute sprite sheet UV.
    float2 uv = float2(gid) / float2(outTex.get_width(), outTex.get_height());

    int col = u.currentFrame % u.spriteColumns;
    int row = u.currentFrame / u.spriteColumns;

    float frameW = 1.0 / float(u.spriteColumns);
    float frameH = 1.0 / float(u.spriteRows);

    float2 spriteUV = float2(
        float(col) * frameW + uv.x * frameW,
        float(row) * frameH + uv.y * frameH
    );

    constexpr sampler samp(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 overlay = overlayTex.sample(samp, spriteUV);

    float alpha = overlay.a * u.opacity;

    float3 blended;
    if (u.blendMode == 1) {
        // Multiply
        blended = base.rgb * overlay.rgb;
    } else if (u.blendMode == 2) {
        // Screen
        blended = 1.0 - (1.0 - base.rgb) * (1.0 - overlay.rgb);
    } else if (u.blendMode == 3) {
        // Overlay (Photoshop-style)
        float3 low  = 2.0 * base.rgb * overlay.rgb;
        float3 high = 1.0 - 2.0 * (1.0 - base.rgb) * (1.0 - overlay.rgb);
        blended = mix(low, high, step(float3(0.5), base.rgb));
    } else {
        // Normal
        blended = overlay.rgb;
    }

    float3 result = mix(base.rgb, blended, alpha);
    outTex.write(float4(result, base.a), gid);
}
