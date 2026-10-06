#include <metal_stdlib>
using namespace metal;

// Shared with FlappyUniforms in FlappyLog.swift. Keep the field order identical.
struct FlappyUniforms {
    float4 view;      // x left world x, y bottom world y, z visible width, w visible height
    float4 time;      // x seconds since start, y simulation step in seconds, z particle count, w 1 after a crash
    float4 log;       // x, y, tilt in radians
    float4 particle;  // x intensity, y size scale
};

// Each column is float4(x, gap center, gap half height, active). Particle i belongs to column i % 8.
constant uint columnCount = 8;
constant float columnHalfWidth = 0.7;
constant float logHalfLength = 0.75;
constant float logRadius = 0.32;
// Upper fire reaches past the top of the screen so it never ends in mid-air.
constant float fireTop = 11.5;
constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

static uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
static float unit(thread uint &seed) { seed = pcg(seed); return float(seed) / 4294967295.0; }
static float hash1(float x) { return float(pcg(uint(int(floor(x)) * 73856093))) / 4294967295.0; }
static float hash2(float2 p) { return float(pcg(uint(int(p.x) * 73856093) ^ uint(int(p.y) * 19349663))) / 4294967295.0; }
static float noise1(float x) { float i = floor(x), f = fract(x); return mix(hash1(i), hash1(i + 1), f * f * (3 - 2 * f)); }
static float noise2(float2 p) {
    float2 i = floor(p), f = fract(p), w = f * f * (3 - 2 * f);
    return mix(mix(hash2(i), hash2(i + float2(1, 0)), w.x), mix(hash2(i + float2(0, 1)), hash2(i + 1), w.x), w.y);
}
static float4 toClip(float2 world, constant FlappyUniforms &u) {
    return float4((world - u.view.xy) / u.view.zw * 2 - 1, 0, 1);
}

// MARK: Fire particles

kernel void flappyParticles(device float4 *particles [[buffer(0)]], constant FlappyUniforms &u [[buffer(1)]],
                            constant float4 *columns [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= uint(u.time.z)) return;
    float4 p = particles[id * 2];       // x relative to the column, y height, w remaining life
    float4 v = particles[id * 2 + 1];   // xy velocity, w per-particle random value
    float4 column = columns[id % columnCount];
    float dt = u.time.y, time = u.time.x;
    float gapLow = column.y - column.z, gapHigh = column.y + column.z;
    p.w -= dt / (0.7 + 0.9 * v.w);
    if (p.y > gapLow && p.y < gapHigh) p.w -= dt * 5;
    if (p.w <= 0 || p.y > fireTop + 0.6 || column.w < 0.5) {
        uint seed = id * 9781u + uint(time * 240.0) * 6271u;
        float x = (unit(seed) * 2 - 1) * 0.6 * pow(unit(seed), 0.5);
        float y = unit(seed) * (gapLow + fireTop - gapHigh);
        if (y > gapLow) y += gapHigh - gapLow;
        p = float4(x, y, 0, column.w < 0.5 ? 0 : 0.6 + 0.4 * unit(seed));
        v = float4(-x * 0.3, 0.8 + 1.6 * unit(seed), 0, unit(seed));
    } else {
        float2 q = p.xy * 1.7 + float2(0, -time * 1.6);
        float swirl = sin(q.y * 2.1 + q.x * 3.0 + time * 2.3) + 0.5 * sin(q.y * 5.3 - time * 3.1);
        v.xy += (float2(swirl * 2.4 - p.x * 3.2, 2.2)) * dt;
        v.xy *= 1 - 1.4 * dt;
        p.xy += v.xy * dt;
    }
    particles[id * 2] = p;
    particles[id * 2 + 1] = v;
}

struct ParticleOut { float4 position [[position]]; float2 corner; float3 color; };

vertex ParticleOut flappyParticleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                        const device float4 *particles [[buffer(0)]],
                                        constant FlappyUniforms &u [[buffer(1)]], constant float4 *columns [[buffer(2)]]) {
    float4 p = particles[iid * 2];
    float4 column = columns[iid % columnCount];
    ParticleOut out;
    out.corner = float2((vid & 1) ? 1 : -1, (vid & 2) ? 1 : -1);
    if (p.w <= 0 || column.w < 0.5) { out.position = float4(0, 0, 2, 1); out.color = 0; return out; }
    float life = saturate(p.w);
    float insideGap = min(p.y - (column.y - column.z), column.y + column.z - p.y);
    float gapFade = 1 - smoothstep(-0.05, 0.25, insideGap);
    float size = (0.06 + 0.2 * life) * u.particle.y;
    out.position = toClip(float2(column.x + p.x, p.y) + out.corner * size, u);
    float3 hot = float3(1.0, 0.55, 0.14), warm = float3(0.9, 0.16, 0.01), cool = float3(0.3, 0.02, 0.005);
    float3 tint = life > 0.5 ? mix(warm, hot, (life - 0.5) * 2) : mix(cool, warm, life * 2);
    float core = exp(-abs(p.x) * 2.5);
    out.color = tint * (0.2 + 1.6 * core * core) * life * gapFade * u.particle.x;
    return out;
}

fragment half4 flappyParticleFragment(ParticleOut in [[stage_in]]) {
    float falloff = max(0.0, exp(-dot(in.corner, in.corner) * 3.5) - exp(-3.5));
    return half4(half3(in.color * falloff), 0);
}

// MARK: Background: sky, hills, forest, braziers, and scorched ground

struct FullscreenOut { float4 position [[position]]; float2 uv; };

vertex FullscreenOut flappyFullscreen(uint vid [[vertex_id]]) {
    float2 point = float2((vid << 1) & 2, vid & 2) * 2 - 1;
    return {float4(point, 0, 1), float2(point.x * 0.5 + 0.5, 0.5 - point.y * 0.5)};
}

/// A silhouette layer that scrolls at `depth` times the camera speed. Returns 1 inside the shape.
static float ridge(float x, float y, float depth, float base, float height, float detail) {
    float shift = x * detail;
    float top = base + height * (noise1(shift) * 0.7 + noise1(shift * 2.7) * 0.3);
    return smoothstep(top + 0.02, top - 0.02, y);
}
/// Pine trees: a row of triangles with varied heights.
static float pines(float x, float y, float base) {
    float cell = floor(x * 1.4), local = fract(x * 1.4) - 0.5;
    float height = 0.9 + 1.4 * hash1(cell + 3.0);
    float width = (1 - saturate((y - base) / height)) * 0.42;
    float tree = step(abs(local), width) * step(base, y) * step(y, base + height);
    float trunk = step(abs(local), 0.05) * step(base - 0.3, y) * step(y, base);
    return max(max(tree, trunk), step(y, base));
}

fragment float4 flappyBackground(FullscreenOut in [[stage_in]], constant FlappyUniforms &u [[buffer(0)]],
                                 constant float4 *columns [[buffer(1)]]) {
    float2 world = u.view.xy + float2(in.uv.x, 1 - in.uv.y) * u.view.zw;
    float time = u.time.x;
    float height = saturate(world.y / 11);
    float3 color = mix(float3(0.16, 0.05, 0.035), float3(0.012, 0.014, 0.04), pow(height, 0.7));
    // Stars drift slowly with the camera.
    float2 starField = float2(world.x * 0.05 + in.uv.x, in.uv.y) * float2(120, 70);
    float star = step(0.996, hash2(floor(starField))) * smoothstep(0.3, 0.05, length(fract(starField) - 0.5));
    color += star * smoothstep(0.35, 0.8, height) * (0.5 + 0.4 * sin(time * 3 + hash2(floor(starField) + 9) * 40)) * 0.7;
    // A low ember moon.
    float2 moon = (in.uv - float2(0.78, 0.28)) * float2(u.view.z / u.view.w, 1);
    color += float3(1.0, 0.45, 0.2) * (smoothstep(0.07, 0.065, length(moon)) * 0.5 + exp(-length(moon) * 9) * 0.25);
    // Three parallax layers, nearer ones darker and faster.
    float far = ridge(world.x * 0.15, world.y, 0.15, 2.5, 3.5, 0.18);
    color = mix(color, float3(0.07, 0.03, 0.04), far);
    float middle = ridge(world.x * 0.35, world.y, 0.35, 1.2, 2.2, 0.35);
    color = mix(color, float3(0.045, 0.02, 0.025), middle);
    float forest = pines(world.x * 0.6, world.y, 0.6);
    color = mix(color, float3(0.02, 0.01, 0.012), forest);

    // Fire columns: a hot haze behind the particles and an iron brazier at each lip of the gap.
    for (uint i = 0; i < columnCount; ++i) {
        float4 column = columns[i];
        if (column.w < 0.5) continue;
        float dx = abs(world.x - column.x);
        float gapLow = column.y - column.z, gapHigh = column.y + column.z;
        bool fire = world.y < gapLow || world.y > gapHigh;
        float flicker = 0.85 + 0.15 * sin(time * 11 + float(i) * 2.1);
        if (fire) color += float3(0.5, 0.1, 0.02) * exp(-dx * dx * 4) * 0.6 * flicker;
        // Light spills into the gap so it reads as an opening.
        float lip = min(abs(world.y - gapLow), abs(world.y - gapHigh));
        color += float3(1.0, 0.4, 0.1) * exp(-lip * 3) * exp(-dx * 2) * 0.12 * flicker;
        for (int side = 0; side < 2; ++side) {
            float edge = side == 0 ? gapLow : gapHigh;
            float y = side == 0 ? world.y - edge + 0.14 : edge + 0.14 - world.y;
            if (dx < columnHalfWidth + 0.12 && y > 0 && y < 0.28) {
                float rim = smoothstep(0.2, 0.28, y);
                float rivets = step(0.8, fract((world.x - column.x) * 3.2 + 0.5)) * step(0.08, y) * step(y, 0.16);
                color = float3(0.09, 0.07, 0.065) * (0.6 + 0.4 * noise2(world * 30)) + float3(1.0, 0.45, 0.12) * rim * flicker
                    + float3(0.3, 0.12, 0.05) * rivets;
            }
        }
    }

    // Scorched ground with glowing embers that scroll with the world.
    if (world.y < 0) {
        float grain = noise2(world * float2(3, 9)) * 0.6 + noise2(world * 17) * 0.4;
        color = mix(float3(0.035, 0.022, 0.02), float3(0.1, 0.06, 0.045), grain);
        float embers = smoothstep(0.72, 0.9, noise2(world * float2(5, 12) + float2(0, time * 0.3)));
        color += float3(1.0, 0.3, 0.05) * embers * (0.6 + 0.4 * sin(time * 4 + world.x * 3));
        color += float3(1.0, 0.4, 0.1) * smoothstep(-0.08, 0.0, world.y) * 0.5;
    }
    return float4(color, 1);
}

// MARK: Log

struct LogOut { float4 position [[position]]; float2 local; };

vertex LogOut flappyLogVertex(uint vid [[vertex_id]], constant FlappyUniforms &u [[buffer(0)]]) {
    float2 corner = float2((vid & 1) ? 1 : -1, (vid & 2) ? 1 : -1);
    float2 local = corner * float2(logHalfLength + 0.25, logRadius + 0.3);
    float c = cos(u.log.z), s = sin(u.log.z);
    float2 world = float2(u.log.x, u.log.y) + float2(local.x * c - local.y * s, local.x * s + local.y * c);
    return {toClip(world, u), local};
}

fragment half4 flappyLog(LogOut in [[stage_in]], constant FlappyUniforms &u [[buffer(0)]]) {
    float2 p = in.local;
    float time = u.time.x;
    // The side of the log is a rounded box. The cut face on the right shows its rings.
    float2 q = abs(p) - float2(logHalfLength - 0.06, logRadius - 0.06);
    float body = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 0.06;
    float2 face = (p - float2(logHalfLength - 0.05, 0)) / float2(0.13, logRadius);
    float cut = length(face) - 1;
    // A small twig with a leaf so the log has a face to fly with.
    float2 twig = p - float2(-0.25, logRadius + 0.06);
    float stick = abs(twig.x + twig.y * 0.5) < 0.035 && twig.y > -0.08 && twig.y < 0.16 ? -1 : 1;
    float2 leafPoint = (p - float2(-0.36, logRadius + 0.2)) * float2(1, 2.2);
    float leaf = length(leafPoint) - 0.1;
    if (body > 0 && cut > 0 && stick > 0 && leaf > 0) {
        // A soft dark outline keeps the log readable against the fire.
        float outline = min(body, cut);
        if (outline < 0.05) return half4(0.02, 0.01, 0.005, 1);
        discard_fragment();
    }
    float3 color;
    if (leaf <= 0) {
        color = float3(0.25, 0.55, 0.15) * (0.7 + 0.3 * leafPoint.y * 5);
    } else if (stick <= 0) {
        color = float3(0.3, 0.18, 0.09);
    } else if (cut <= 0) {
        float rings = fract(length(face) * 4.5 + noise2(face * 6) * 0.4);
        color = mix(float3(0.85, 0.63, 0.38), float3(0.55, 0.35, 0.18), smoothstep(0.55, 0.9, rings));
        color *= 0.85 + 0.15 * (1 - length(face));
    } else {
        float grooves = noise2(float2(p.x * 3, p.y * 26));
        float3 bark = mix(float3(0.17, 0.095, 0.05), float3(0.42, 0.26, 0.13), smoothstep(0.3, 0.75, grooves));
        float knot = smoothstep(0.09, 0.05, length((p - float2(-0.45, -0.05)) * float2(1, 1.6)));
        bark = mix(bark, float3(0.12, 0.06, 0.03), knot);
        // Round shading: light on top, darker underneath.
        float round = sqrt(saturate(1 - pow(p.y / logRadius, 2)));
        color = bark * (0.45 + 0.75 * round * (0.6 + 0.4 * (p.y / logRadius + 1) * 0.5));
    }
    // Firelight from below and a warm rim.
    color += float3(0.5, 0.18, 0.05) * smoothstep(0.0, -logRadius, p.y) * 0.25;
    if (u.time.w > 0.5) {
        float embers = smoothstep(0.45, 0.8, noise2(p * float2(8, 14) + float2(0, time * 1.5)));
        color = color * 0.35 + float3(1.0, 0.32, 0.05) * embers * (2.5 + sin(time * 17));
    }
    return half4(half3(color), 1);
}

// MARK: Glow and final image

fragment half4 flappyBrightPass(FullscreenOut in [[stage_in]], texture2d<half> scene [[texture(0)]]) {
    half3 color = scene.sample(linearClamp, in.uv).rgb;
    return half4(max(color - 0.8h, 0.0h), 1);
}

fragment half4 flappyCopy(FullscreenOut in [[stage_in]], texture2d<half> source [[texture(0)]]) {
    return source.sample(linearClamp, in.uv);
}

fragment half4 flappyBlur(FullscreenOut in [[stage_in]], texture2d<half> source [[texture(0)]],
                          constant float2 &direction [[buffer(0)]]) {
    const float weights[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};
    half3 color = source.sample(linearClamp, in.uv).rgb * weights[0];
    for (int i = 1; i < 5; ++i) {
        color += source.sample(linearClamp, in.uv + direction * float(i) * 1.5).rgb * weights[i];
        color += source.sample(linearClamp, in.uv - direction * float(i) * 1.5).rgb * weights[i];
    }
    return half4(color, 1);
}

fragment float4 flappyComposite(FullscreenOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                                texture2d<float> glow [[texture(1)]], texture2d<float> wideGlow [[texture(2)]],
                                constant FlappyUniforms &u [[buffer(0)]]) {
    float heat = saturate(dot(wideGlow.sample(linearClamp, in.uv).rgb, float3(0.3, 0.5, 0.2)) * 1.5);
    float2 shimmer = float2(noise2(in.uv * float2(60, 30) + float2(0, u.time.x * 3)),
                            noise2(in.uv * float2(60, 30) + float2(17, u.time.x * 3.4))) - 0.5;
    float2 uv = in.uv + shimmer * heat * 0.004;
    float3 color = scene.sample(linearClamp, uv).rgb + glow.sample(linearClamp, uv).rgb * 0.6
        + wideGlow.sample(linearClamp, uv).rgb * 0.9;
    color = saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));
    float2 centered = in.uv - 0.5;
    color *= 1 - dot(centered, centered) * 0.6;
    return float4(pow(color, 1 / 2.2), 1);
}
