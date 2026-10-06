#include <metal_stdlib>
using namespace metal;
struct VertexOutput { float4 position [[position]]; float2 uv; };
vertex VertexOutput fullscreen(uint id [[vertex_id]]) {
    float2 points[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return {float4(points[id], 0, 1), points[id]};
}
/// Each piece is a log level, colored like Logfire colors them: trace, debug, info, notice, warn, error, fatal.
float3 palette(int value) {
    float3 colors[] = {float3(0.62, 0.6, 0.74), float3(0.25, 0.82, 0.9), float3(0.35, 0.6, 1.0),
        float3(0.3, 0.85, 0.55), float3(1.0, 0.78, 0.22), float3(1.0, 0.32, 0.3), float3(0.88, 0.3, 1.0)};
    return colors[clamp(value - 1, 0, 6)];
}
static float stackHash(float2 p) {
    uint v = uint(int(p.x) * 73856093) ^ uint(int(p.y) * 19349663);
    v = v * 747796405u + 2891336453u; v = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
    return float((v >> 22u) ^ v) / 4294967295.0;
}
static float stackNoise(float2 p) {
    float2 i = floor(p), f = fract(p), w = f * f * (3 - 2 * f);
    return mix(mix(stackHash(i), stackHash(i + float2(1, 0)), w.x), mix(stackHash(i + float2(0, 1)), stackHash(i + 1), w.x), w.y);
}
/// Flames rising through a burning cell. `p` is in board cells, so neighbouring cells flow together.
static float flames(float2 p, float time) {
    float rise = stackNoise(float2(p.x * 2.2, p.y * 1.6 + time * 3.2)) * 0.65 + stackNoise(float2(p.x * 5, p.y * 4 + time * 5.5)) * 0.35;
    return smoothstep(0.35, 0.85, rise);
}
/// Sparks drifting up from the fire under the board. `uv` runs from the top (0) to the bottom (1).
static float3 embers(float2 uv, float time) {
    float3 light = 0;
    for (int layer = 0; layer < 3; ++layer) {
        float scale = 9 + float(layer) * 6;
        float2 p = float2(uv.x * scale + sin(uv.y * 9 + time + float(layer)) * 0.3, (uv.y + time * (0.07 + 0.03 * float(layer))) * scale * 2);
        float2 id = floor(p), offset = float2(stackHash(id + 31), stackHash(id + 57)) - 0.5;
        if (stackHash(id + float(layer) * 17) < 0.8) continue;
        float spark = smoothstep(0.12, 0.0, length((fract(p) - 0.5 - offset * 0.6) * float2(1, 0.6)));
        light += mix(float3(1.0, 0.3, 0.05), float3(1.0, 0.75, 0.3), stackHash(id + 5)) * spark * (0.35 - 0.08 * float(layer));
    }
    return light * smoothstep(0.1, 1.0, uv.y);
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
        float3 tint = mix(float3(1.0, 0.42, 0.08), float3(0.9, 0.15, 0.4), 0.5 + 0.5 * sin(seed));
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
    float3 color = neon ? mix(float3(0.03, 0.02, 0.025), float3(0.07, 0.03, 0.02), uv.y)
                        : float3(0.035, 0.03, 0.03);
    if (neon) {
        // A campfire glows under the board.
        float flicker = 0.85 + 0.15 * sin(state.z * 7.3) * sin(state.z * 3.1 + uv.x * 4);
        color += float3(1.0, 0.33, 0.06) * exp(-(1 - uv.y) * 7) * 0.4 * flicker + embers(uv, state.z);
    }
    if (state.w > 1.5) color += aurora(uv, state.z, auroraLayers) * 0.6;
    float line = 1 - smoothstep(0.015, 0.035, min(min(local.x, 1-local.x), min(local.y, 1-local.y)));
    color += line * float3(0.05, 0.035, 0.03);
    if (neon) {
        for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
            int2 neighbor = cell + int2(x, y);
            if (neighbor.x < 0 || neighbor.x >= 10 || neighbor.y < 0 || neighbor.y >= 20) continue;
            int value = cells[neighbor.y * 10 + neighbor.x];
            float halo = exp(-max(0.0, blockDistance(local - float2(x, y))) * 3.8);
            if (value > 0 && value < 10) color += palette(value) * halo * 0.32;
            if (value > 20 && value < 30) color += float3(1.0, 0.4, 0.08) * halo * (0.5 + 0.2 * sin(state.z * 13 + float(neighbor.x)));
        }
    }
    int raw = cells[cell.y * 10 + cell.x];
    // Values above 20 belong to a burning log: charred wood with flames licking up through it.
    bool burning = raw > 20;
    int value = burning ? raw - 20 : raw;
    float distance = blockDistance(local);
    if (value > 10) {
        float outline = 1 - smoothstep(0.015, 0.04, abs(distance));
        color = mix(color, burning ? float3(1.0, 0.45, 0.1) * 0.8 : palette(value - 10) * 0.6, outline * 0.55);
    } else if (value > 0 && burning) {
        float fill = 1 - smoothstep(-0.015, 0.025, distance);
        float2 board = grid * float2(1, -1);
        float bark = stackNoise(float2(grid.x * 3, grid.y * 14));
        float3 wood = mix(float3(0.12, 0.06, 0.03), float3(0.32, 0.18, 0.08), bark);
        float fire = neon ? flames(board, state.z) : 0.5;
        float3 block = wood + float3(1.0, 0.42, 0.08) * fire * (neon ? 1.9 : 0.8) + float3(1.0, 0.8, 0.4) * pow(fire, 4.0) * 0.6;
        color = mix(color, block, fill);
    } else if (value > 0) {
        // A log record: dark card, level stripe on the left, two lines of "text".
        float fill = 1 - smoothstep(-0.015, 0.025, distance);
        float rim = 1 - smoothstep(0.01, 0.05, abs(distance));
        float3 level = palette(value);
        float3 block = mix(float3(0.06, 0.05, 0.06), level, neon ? 0.28 : 0.22) + rim * level * (neon ? 0.7 : 0.35);
        float stripe = step(0.2, local.x) * step(local.x, 0.3) * step(0.22, local.y) * step(local.y, 0.78);
        float length1 = 0.62 + 0.2 * stackHash(float2(cell) + 3), length2 = 0.48 + 0.25 * stackHash(float2(cell) + 11);
        float text = step(0.38, local.x) * (step(abs(local.y - 0.38), 0.045) * step(local.x, length1)
                                          + step(abs(local.y - 0.62), 0.045) * step(local.x, length2));
        block = mix(block, level * (neon ? 1.25 : 1.0), stripe);
        block = mix(block, float3(0.92, 0.88, 0.85), text * 0.55);
        color = mix(color, block, fill);
    }
    if (neon) color *= 0.94 + 0.06 * sin(uv.y * state.y * 2.0 + state.z * 0.3);
    if (effect.x >= 0) {
        float progress = effect.x;
        float fade = (1 - progress) * (1 - progress);
        bool fire = (clearedRows >> 31) != 0;
        bool special = effect.z > 0.5 || effect.y == 4 || fire;
        float3 accent = effect.z > 0.5 ? float3(1.0, 0.35, 0.65) : fire ? float3(1.0, 0.45, 0.1) : float3(1.0, 0.72, 0.3);
        bool cleared = (clearedRows & (1u << uint(cell.y))) != 0;
        if (effect.w > 0.5) {
            if (cleared) color = mix(color, accent, fade * 0.35);
        } else {
            if (cleared && fire) {
                // Burned rows go up in flames that fade as the rows above fall.
                float flame = flames(grid * float2(1, -1), state.z + progress * 2);
                color += accent * fade * (0.5 + flame * 2.2) + float3(1.0, 0.85, 0.5) * pow(flame, 3.0) * fade;
            } else if (cleared) {
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
