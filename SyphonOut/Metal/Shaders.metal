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

// MARK: - Fit uniforms (shared by passthrough and crossfade)
//
// minUV / maxUV define the visible rect in screen UV space [0,1].
// fill mode  → minUV=(0,0) maxUV=(1,1)  → identity, no bars
// fit  mode  → letterbox/pillarbox rect; pixels outside → black
struct FitUniforms {
    float2 minUV;   // top-left  of the visible rect  (e.g. 0.1, 0.0 for pillarbox)
    float2 maxUV;   // bot-right of the visible rect  (e.g. 0.9, 1.0)
};

// Remap a screen UV that falls inside [fit.minUV, fit.maxUV] to texture [0,1].
// Returns (remapped uv, true) or (0, false) if outside (→ black).
static float2 fitUV(float2 uv, FitUniforms fit, thread bool &inside) {
    inside = all(uv >= fit.minUV) && all(uv <= fit.maxUV);
    return (uv - fit.minUV) / (fit.maxUV - fit.minUV);
}

// MARK: - Passthrough

fragment float4 passthroughFragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant FitUniforms &fit [[buffer(0)]],
    sampler smp [[sampler(0)]]
) {
    bool inside;
    float2 uv = fitUV(in.texCoord, fit, inside);
    if (!inside) return float4(0, 0, 0, 1);
    return tex.sample(smp, uv);
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
    constant FitUniforms &fit [[buffer(1)]],
    sampler smp [[sampler(0)]]
) {
    bool inside;
    float2 uv = fitUV(in.texCoord, fit, inside);
    if (!inside) return float4(0, 0, 0, 1);
    float4 colorA = texA.sample(smp, uv);
    float4 colorB = texB.sample(smp, uv);
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

// MARK: - SMPTE EBU Color Bars (GPU-generated, no texture required)
//
// Renders standard 75% SMPTE color bars: top 2/3 = 7 bars, bottom 1/3 = PLUGE.
// All computation is procedural in the fragment shader — zero CPU involvement.

fragment float4 smpteBarsFragment(VertexOut in [[stage_in]]) {
    float x = in.texCoord.x;
    float y = in.texCoord.y;

    // Top 2/3: 7 SMPTE color bars at 75% luminance
    if (y < 0.667) {
        int bar = int(x * 7.0);
        // SMPTE order: White, Yellow, Cyan, Green, Magenta, Red, Blue
        float4 bars[7] = {
            float4(0.75, 0.75, 0.75, 1.0), // White
            float4(0.75, 0.75, 0.00, 1.0), // Yellow
            float4(0.00, 0.75, 0.75, 1.0), // Cyan
            float4(0.00, 0.75, 0.00, 1.0), // Green
            float4(0.75, 0.00, 0.75, 1.0), // Magenta
            float4(0.75, 0.00, 0.00, 1.0), // Red
            float4(0.00, 0.00, 0.75, 1.0), // Blue
        };
        return bars[clamp(bar, 0, 6)];
    }

    // Bottom 1/3: PLUGE (Picture Line-Up Generation Equipment)
    // Divided into 4 zones: -I, White 100%, +Q, Black/PLUGE
    float xInBottom = x;
    if (xInBottom < 0.125) {
        return float4(0.0, 0.105, 0.3, 1.0); // -I (dark blue-violet)
    } else if (xInBottom < 0.375) {
        return float4(1.0, 1.0, 1.0, 1.0);  // 100% White
    } else if (xInBottom < 0.5) {
        return float4(0.19, 0.0, 0.3, 1.0); // +Q (dark purple)
    } else {
        // PLUGE: three sub-zones — super-black, black, near-black
        float xPluge = (xInBottom - 0.5) / 0.5;
        if (xPluge < 0.333) {
            return float4(0.033, 0.033, 0.033, 1.0); // 3.5% (super-black)
        } else if (xPluge < 0.667) {
            return float4(0.0,   0.0,   0.0,   1.0); // 0% Black
        } else {
            return float4(0.07,  0.07,  0.07,  1.0); // 7% (near-black)
        }
    }
}
