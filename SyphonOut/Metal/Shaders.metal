#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Full-screen quad vertices (two triangles)
constant float2 quadVertices[] = {
    float2(-1,  1), float2( 1,  1),
    float2(-1, -1), float2( 1, -1),
    float2( 1,  1), float2(-1, -1)
};

vertex VertexOut vertexShader(uint vid [[vertex_id]]) {
    VertexOut out;
    float2 pos = quadVertices[vid];
    out.position = float4(pos, 0, 1);
    // Flip Y: Metal UV origin is top-left, Syphon textures are bottom-left
    out.texCoord = float2((pos.x + 1.0) * 0.5, (1.0 - pos.y) * 0.5);
    return out;
}

// MARK: - Passthrough

fragment float4 passthroughFragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    return tex.sample(smp, in.texCoord);
}

// MARK: - Crossfade blend (A → B over alpha 0→1)

struct CrossfadeUniforms {
    float alpha;
};

fragment float4 crossfadeFragment(
    VertexOut in [[stage_in]],
    texture2d<float> texA [[texture(0)]],   // previous (outgoing)
    texture2d<float> texB [[texture(1)]],   // current  (incoming)
    constant CrossfadeUniforms &u [[buffer(0)]],
    sampler smp [[sampler(0)]]
) {
    float4 colorA = texA.sample(smp, in.texCoord);
    float4 colorB = texB.sample(smp, in.texCoord);
    return mix(colorA, colorB, u.alpha);
}

// MARK: - Solid color (blank mode)

struct SolidColorUniforms {
    float4 color;
};

fragment float4 solidColorFragment(
    VertexOut in [[stage_in]],
    constant SolidColorUniforms &u [[buffer(0)]]
) {
    return u.color;
}
