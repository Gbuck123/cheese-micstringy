// BlitShaders.metal
// Vertex and fragment shaders for rendering a full-screen textured quad.
// Used by ScaledBlitRenderer to display the final processed texture in MTKView.

#include <metal_stdlib>
using namespace metal;

struct BlitVertexIn {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct BlitVertexOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex BlitVertexOut blitVertex(uint vid [[vertex_id]],
                                 constant float4 *vertices [[buffer(0)]]) {
    // Each vertex is packed as (x, y, u, v) in a float4.
    float4 v = vertices[vid];
    BlitVertexOut out;
    out.position = float4(v.x, v.y, 0.0, 1.0);
    out.texcoord = float2(v.z, v.w);
    return out;
}

fragment float4 blitFragment(BlitVertexOut in [[stage_in]],
                              texture2d<float, access::sample> tex [[texture(0)]],
                              sampler samp [[sampler(0)]]) {
    return tex.sample(samp, in.texcoord);
}
