// StyleBlendShader.metal
// Dedicated blend kernel for mixing the Neural Engine style-transfer output
// with the original camera frame. Supports temporal smoothing to reduce flicker
// when the ANE runs at a lower FPS than the camera.

#include <metal_stdlib>
using namespace metal;

struct StyleBlendUniforms {
    float mix;              // 0 = original, 1 = fully stylised
    float temporalBlend;    // 0..1 blend with previous frame's stylised output
};

/// Blend the original camera frame with the stylised output from the Neural Engine.
/// The stylised texture may be at a different resolution (e.g., 512x512) — we sample it.
kernel void styleBlend(
    texture2d<float, access::read>   originalTex  [[texture(0)]],
    texture2d<float, access::write>  outTex       [[texture(1)]],
    texture2d<float, access::sample> stylisedTex  [[texture(2)]],
    texture2d<float, access::sample> prevStylised [[texture(3)]],
    constant StyleBlendUniforms &u                [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float4 original = originalTex.read(gid);

    float2 uv = float2(gid) / float2(outTex.get_width(), outTex.get_height());
    constexpr sampler samp(coord::normalized, filter::linear, address::clamp_to_edge);

    float4 stylised = stylisedTex.sample(samp, uv);

    // Temporal blending: smooth transitions when the ANE produces results at lower FPS.
    if (u.temporalBlend > 0.001) {
        float4 prev = prevStylised.sample(samp, uv);
        stylised = mix(stylised, prev, u.temporalBlend);
    }

    float4 result = mix(original, stylised, u.mix);
    result.a = 1.0;
    outTex.write(result, gid);
}

// ============================================================================
// MARK: - CIKernel-compatible Metal function
// ============================================================================
// This function can be compiled into a CIColorKernel using the -fcikernel flag.
// It's provided as an example of writing a custom Core Image kernel in Metal.
//
// Compile with:
//   xcrun metal -fcikernel -c CICustomKernels.ci.metal -o CICustomKernels.ci.air
//   xcrun metallib -cikernel CICustomKernels.ci.air -o CICustomKernels.ci.metallib

/*
// Uncomment and place in a separate .ci.metal file for Core Image kernel compilation.

#include <CoreImage/CoreImage.h>

extern "C" float4 ciSepiaKernel(coreimage::sample_t s, float intensity) {
    float lum = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float3 sepia = float3(lum * 1.2, lum * 1.0, lum * 0.8);
    float3 result = mix(s.rgb, sepia, intensity);
    return float4(result, s.a);
}
*/
