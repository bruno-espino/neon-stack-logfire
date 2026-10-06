#include <metal_stdlib>
using namespace metal;
struct VertexOutput { float4 position [[position]]; float2 uv; };
vertex VertexOutput fullscreen(uint id [[vertex_id]]) {
    float2 points[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return {float4(points[id], 0, 1), points[id]};
}
float3 palette(int value) {
    float3 colors[] = {float3(0.12, 0.91, 0.96), float3(1.0, 0.83, 0.25), float3(0.72, 0.36, 1.0),
        float3(0.26, 0.94, 0.58), float3(1.0, 0.32, 0.48), float3(1.0, 0.57, 0.24), float3(0.28, 0.52, 1.0)};
    return colors[clamp(value - 1, 0, 6)];
}
float blockDistance(float2 p) {
    float2 q = abs(p - 0.5) - 0.35;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 0.055;
}
float3 aurora(float2 uv, float time, uint layers) {
    float3 light = 0;
    for (uint i = 0; i < min(layers, 48u); ++i) {
        float seed = float(i) * 2.39996;
        float center = 0.5 + 0.33 * sin(seed + uv.x * 2.8 + time * 0.12)
            + 0.08 * sin(uv.x * 14 + seed * 1.7 - time * 0.24);
        float ribbon = exp(-abs(uv.y - center) * (22 + 10 * sin(seed)));
        float folds = 0.5 + 0.5 * sin(uv.x * (32 + float(i)) + seed + time * 0.4);
        float3 tint = mix(float3(0.12, 0.8, 0.66), float3(0.58, 0.2, 0.9), 0.5 + 0.5 * sin(seed));
        light += tint * ribbon * folds;
    }
    return light * (4.0 / max(float(layers), 1.0));
}
fragment float4 neonStack(VertexOutput in [[stage_in]], constant float4 &state [[buffer(0)]], constant int *cells [[buffer(1)]],
                         constant float4 &effect [[buffer(2)]], constant uint &clearedRows [[buffer(3)]],
                         constant uint &auroraLayers [[buffer(4)]]) {
    float2 uv = float2((in.uv.x + 1) * 0.5, (1 - in.uv.y) * 0.5);
    float2 grid = uv * float2(10, 20);
    int2 cell = clamp(int2(floor(grid)), int2(0), int2(9, 19));
    float2 local = fract(grid);
    bool neon = state.w > 0.5;
    float3 color = neon ? mix(float3(0.017, 0.026, 0.05), float3(0.03, 0.055, 0.09), uv.y)
                        : float3(0.025, 0.03, 0.04);
    if (state.w > 1.5) color += aurora(uv, state.z, auroraLayers);
    float line = 1 - smoothstep(0.015, 0.035, min(min(local.x, 1-local.x), min(local.y, 1-local.y)));
    color += line * float3(0.023, 0.037, 0.048);
    if (neon) {
        for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
            int2 neighbor = cell + int2(x, y);
            if (neighbor.x < 0 || neighbor.x >= 10 || neighbor.y < 0 || neighbor.y >= 20) continue;
            int value = cells[neighbor.y * 10 + neighbor.x];
            if (value > 0 && value < 10) color += palette(value) * exp(-max(0.0, blockDistance(local - float2(x, y))) * 3.8) * 0.32;
        }
    }
    int value = cells[cell.y * 10 + cell.x];
    float distance = blockDistance(local);
    if (value > 10) {
        float outline = 1 - smoothstep(0.015, 0.04, abs(distance));
        color = mix(color, palette(value - 10) * 0.6, outline * 0.55);
    } else if (value > 0) {
        float fill = 1 - smoothstep(-0.015, 0.025, distance);
        float rim = 1 - smoothstep(0.01, 0.05, abs(distance));
        float3 block = neon ? palette(value) * (0.75 + 0.3 * (1-local.y)) + rim * 0.32 : palette(value) * 0.85;
        color = mix(color, block, fill);
    }
    if (neon) color *= 0.94 + 0.06 * sin(uv.y * state.y * 2.0 + state.z * 0.3);
    if (effect.x >= 0) {
        float progress = effect.x;
        float fade = (1 - progress) * (1 - progress);
        bool special = effect.z > 0.5 || effect.y == 4;
        float3 accent = effect.z > 0.5 ? float3(1.0, 0.8, 0.3) : float3(0.3, 0.95, 1.0);
        bool cleared = (clearedRows & (1u << uint(cell.y))) != 0;
        if (effect.w > 0.5) {
            if (cleared) color = mix(color, accent, fade * 0.35);
        } else {
            if (cleared) {
                float sweep = exp(-pow((uv.x - progress * 1.4 + 0.2) * 8, 2.0));
                color += accent * fade * (0.3 + sweep * 1.4);
                float sparks = pow(max(0.0, sin(uv.x * 180 + float(cell.y) * 7 - progress * 24)), 24.0);
                color += accent * sparks * fade * (1 - abs(local.y - 0.5) * 2);
            }
            if (special) {
                float2 center = (uv - float2(0.5, effect.z > 0.5 ? 0.5 : 0.9)) * float2(0.5, 1);
                float radius = length(center);
                float ring = exp(-pow((radius - progress * 0.85) * 45, 2.0));
                float rays = pow(max(0.0, cos(atan2(center.y, center.x) * 14 + progress * 3)), 16.0);
                color += accent * fade * (ring * 1.1 + rays * exp(-radius * 4) * 0.45);
            }
        }
    }
    return float4(color, 1);
}
