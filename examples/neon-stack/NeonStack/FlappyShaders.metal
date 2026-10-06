#include <metal_stdlib>
using namespace metal;

// Shared with FlappyUniforms in FlappyLog.swift. Keep the field order identical.
struct FlappyUniforms {
    float4x4 viewProjection;
    float4 camera;    // xyz eye position, w seconds since start
    float4 right;     // xyz camera right, w simulation step in seconds
    float4 up;        // xyz camera up, w particle count
    float4 log;       // x, y, tilt in radians, 1 after a crash
    float4 particle;  // x intensity, y size scale
};

// Each column is float4(x, gap center, gap half height, active). Particle i belongs to column i % 8.
constant uint columnCount = 8;
constant float worldHeight = 10.0;
// Upper fire reaches past the playable ceiling so it never ends in mid-air on screen.
constant float fireTop = 14.0;
constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

static uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
static float unit(thread uint &seed) { seed = pcg(seed); return float(seed) / 4294967295.0; }
static float hash2(float2 p) { return float(pcg(uint(int(p.x) * 73856093) ^ uint(int(p.y) * 19349663))) / 4294967295.0; }
static float noise2(float2 p) {
    float2 i = floor(p), f = fract(p), w = f * f * (3 - 2 * f);
    return mix(mix(hash2(i), hash2(i + float2(1, 0)), w.x), mix(hash2(i + float2(0, 1)), hash2(i + 1), w.x), w.y);
}

// MARK: Particle simulation

kernel void flappyParticles(device float4 *particles [[buffer(0)]], constant FlappyUniforms &u [[buffer(1)]],
                            constant float4 *columns [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= uint(u.up.w)) return;
    float4 p = particles[id * 2];       // xyz position (x and z relative to the column), w remaining life
    float4 v = particles[id * 2 + 1];   // xyz velocity, w per-particle random value
    float4 column = columns[id % columnCount];
    float dt = u.right.w, time = u.camera.w;
    float gapLow = column.y - column.z, gapHigh = column.y + column.z;
    p.w -= dt / (0.7 + 0.9 * v.w);
    if (p.y > gapLow && p.y < gapHigh) p.w -= dt * 5;
    if (p.w <= 0 || p.y > fireTop + 0.6 || column.w < 0.5) {
        uint seed = id * 9781u + uint(time * 240.0) * 6271u;
        float angle = unit(seed) * 6.2831853, radius = 0.62 * pow(unit(seed), 0.6);
        float y = unit(seed) * (gapLow + fireTop - gapHigh);
        if (y > gapLow) y += gapHigh - gapLow;
        p = float4(cos(angle) * radius, y, sin(angle) * radius, column.w < 0.5 ? 0 : 0.6 + 0.4 * unit(seed));
        v = float4(-p.x * 0.3, 0.8 + 1.6 * unit(seed), -p.z * 0.3, unit(seed));
    } else {
        float3 q = p.xyz * 1.7 + float3(0, -time * 1.6, 0);
        float3 swirl = float3(sin(q.y * 2.1 + q.z * 3.0 + time * 2.3), 0, cos(q.y * 2.4 + q.x * 3.3 - time * 1.9));
        v.xyz += (swirl * 2.2 + float3(-p.x, 0, -p.z) * 2.8 + float3(0, 2.2, 0)) * dt;
        v.xyz *= 1 - 1.4 * dt;
        p.xyz += v.xyz * dt;
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
    float3 world = float3(column.x + p.x, p.y, p.z) + (u.right.xyz * out.corner.x + u.up.xyz * out.corner.y) * size;
    out.position = u.viewProjection * float4(world, 1);
    float3 hot = float3(1.0, 0.55, 0.14), warm = float3(0.9, 0.16, 0.01), cool = float3(0.3, 0.02, 0.005);
    float3 tint = life > 0.5 ? mix(warm, hot, (life - 0.5) * 2) : mix(cool, warm, life * 2);
    float core = exp(-length(p.xz) * 2.5);
    out.color = tint * (0.2 + 1.6 * core * core) * life * gapFade * u.particle.x;
    return out;
}

fragment half4 flappyParticleFragment(ParticleOut in [[stage_in]]) {
    float falloff = max(0.0, exp(-dot(in.corner, in.corner) * 3.5) - exp(-3.5));
    return half4(half3(in.color * falloff), 0);
}

// MARK: Lighting shared by the ground and the log

static float3 fireLight(float3 position, float3 normal, constant float4 *columns, float time) {
    float3 light = 0;
    for (uint i = 0; i < columnCount; ++i) {
        float4 column = columns[i];
        if (column.w < 0.5) continue;
        float gapLow = column.y - column.z, gapHigh = column.y + column.z;
        float flicker = 0.82 + 0.18 * sin(time * 13 + float(i) * 1.7) * sin(time * 7.3 + float(i));
        float heights[4] = {gapLow * 0.5, gapLow - 0.2, gapHigh + 0.2, (gapHigh + fireTop) * 0.5};
        for (uint k = 0; k < 4; ++k) {
            float3 toLight = float3(column.x, heights[k], 0) - position;
            float facing = max(dot(normal, normalize(toLight)), 0.0);
            light += float3(1.0, 0.45, 0.12) * facing * flicker * 2.2 / (1 + dot(toLight, toLight) * 0.55);
        }
    }
    return light;
}

static float3 skyColor(float height) {
    return mix(float3(0.09, 0.035, 0.04), float3(0.008, 0.01, 0.03), saturate(height));
}

// MARK: Sky, ground, and log

struct FullscreenOut { float4 position [[position]]; float2 uv; };

vertex FullscreenOut flappyFullscreen(uint vid [[vertex_id]]) {
    float2 point = float2((vid << 1) & 2, vid & 2) * 2 - 1;
    return {float4(point, 0, 1), float2(point.x * 0.5 + 0.5, 0.5 - point.y * 0.5)};
}

fragment float4 flappySky(FullscreenOut in [[stage_in]], constant FlappyUniforms &u [[buffer(0)]]) {
    float3 color = skyColor(1.15 - in.uv.y * 1.6);
    float2 starField = (in.uv + float2(u.log.x * 0.004, 0)) * float2(260, 150);
    float star = step(0.995, hash2(floor(starField))) * (1 - in.uv.y);
    color += star * (0.5 + 0.5 * sin(u.camera.w * 3 + hash2(floor(starField) + 7) * 40)) * 0.6;
    return float4(color, 1);
}

struct SurfaceOut { float4 position [[position]]; float3 world; float3 normal; float3 local; };

vertex SurfaceOut flappyGroundVertex(uint vid [[vertex_id]], constant FlappyUniforms &u [[buffer(0)]]) {
    float2 corners[6] = {float2(0, 0), float2(1, 0), float2(1, 1), float2(0, 0), float2(1, 1), float2(0, 1)};
    float2 c = corners[vid];
    float3 world = float3(u.log.x - 40 + c.x * 200, 0, -150 + c.y * 160);
    return {u.viewProjection * float4(world, 1), world, float3(0, 1, 0), 0};
}

fragment float4 flappyGround(SurfaceOut in [[stage_in]], constant FlappyUniforms &u [[buffer(0)]],
                             constant float4 *columns [[buffer(1)]]) {
    float2 p = in.world.xz;
    float2 tile = fract(p * 0.6);
    float seam = smoothstep(0.0, 0.06, min(min(tile.x, 1 - tile.x), min(tile.y, 1 - tile.y)));
    float grain = noise2(p * 3.1) * 0.6 + noise2(p * 11.0) * 0.4;
    float3 albedo = mix(float3(0.05, 0.045, 0.045), float3(0.13, 0.11, 0.1), grain) * (0.55 + 0.45 * seam);
    float3 color = albedo * (float3(0.06, 0.07, 0.12) + fireLight(in.world, in.normal, columns, u.camera.w));
    for (uint i = 0; i < columnCount; ++i) {
        if (columns[i].w < 0.5) continue;
        float distance = length(p - float2(columns[i].x, 0));
        float embers = smoothstep(0.55, 0.9, noise2(p * 7 + float2(0, u.camera.w * 0.7)));
        color = color * (0.35 + 0.65 * smoothstep(0.4, 1.6, distance))
            + float3(1.0, 0.35, 0.06) * embers * exp(-distance * distance * 2.5) * 1.6;
    }
    float fog = 1 - exp(-length(in.world - u.camera.xyz) * 0.05);
    return float4(mix(color, skyColor(0.4), fog), 1);
}

vertex SurfaceOut flappyLogVertex(uint vid [[vertex_id]], constant FlappyUniforms &u [[buffer(0)]]) {
    const uint segments = 32;
    const float radius = 0.32, halfLength = 0.75;
    float along, angle, radial = 1, cap = 0;
    if (vid < segments * 6) {
        uint corner = vid % 6;
        uint segment = vid / 6 + ((corner == 1 || corner == 2 || corner == 4) ? 1 : 0);
        along = (corner == 2 || corner == 4 || corner == 5) ? halfLength : -halfLength;
        angle = 6.2831853 * float(segment) / float(segments);
    } else {
        uint index = vid - segments * 6;
        uint corner = index % 3;
        cap = index / (segments * 3) == 0 ? -1 : 1;
        along = cap * halfLength;
        angle = 6.2831853 * float(index % (segments * 3) / 3 + (corner == 2 ? 1 : 0)) / float(segments);
        radial = corner == 0 ? 0 : 1;
    }
    float bumps = 1 + 0.05 * sin(angle * 7 + along * 3) * (cap == 0 ? 1 : 0);
    float3 local = float3(along, cos(angle) * radius * radial * bumps, sin(angle) * radius * radial * bumps);
    float3 normal = cap == 0 ? float3(0, cos(angle), sin(angle)) : float3(cap, 0, 0);
    float c = cos(u.log.z), s = sin(u.log.z);
    float3x3 tilt = float3x3(float3(c, s, 0), float3(-s, c, 0), float3(0, 0, 1));
    float3 world = tilt * local + float3(u.log.x, u.log.y, 0);
    return {u.viewProjection * float4(world, 1), world, tilt * normal, float3(along, angle, cap == 0 ? -1 : radial * 0)};
}

fragment float4 flappyLog(SurfaceOut in [[stage_in]], constant FlappyUniforms &u [[buffer(0)]],
                          constant float4 *columns [[buffer(1)]]) {
    float3 normal = normalize(in.normal);
    float3 albedo;
    if (in.local.z < 0) {
        float groove = noise2(float2(in.local.y * 9, in.local.x * 2.5));
        albedo = mix(float3(0.11, 0.065, 0.035), float3(0.3, 0.19, 0.1), smoothstep(0.25, 0.75, groove));
    } else {
        float2 face = (in.world.xy - u.log.xy);
        float rings = fract(length(face) * 22 + noise2(face * 12) * 0.6);
        albedo = mix(float3(0.62, 0.45, 0.27), float3(0.42, 0.27, 0.14), smoothstep(0.6, 0.9, rings));
    }
    float3 view = normalize(u.camera.xyz - in.world);
    float rim = pow(1 - saturate(dot(normal, view)), 3) * 0.25;
    float3 color = albedo * (float3(0.12, 0.13, 0.2) + fireLight(in.world, normal, columns, u.camera.w))
        + float3(1.0, 0.4, 0.1) * rim;
    if (u.log.w > 0.5) {
        float embers = smoothstep(0.5, 0.85, noise2(float2(in.local.x * 6, in.local.y * 4) + u.camera.w * 1.5));
        color += float3(1.0, 0.32, 0.05) * embers * (2.5 + sin(u.camera.w * 17));
    }
    return float4(color, 1);
}

// MARK: Glow and final image

fragment half4 flappyBrightPass(FullscreenOut in [[stage_in]], texture2d<half> scene [[texture(0)]]) {
    half3 color = scene.sample(linearClamp, in.uv).rgb;
    return half4(max(color - 0.9h, 0.0h), 1);
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
    float2 shimmer = float2(noise2(in.uv * float2(60, 30) + float2(0, u.camera.w * 3)),
                            noise2(in.uv * float2(60, 30) + float2(17, u.camera.w * 3.4))) - 0.5;
    float2 uv = in.uv + shimmer * heat * 0.004;
    float3 color = scene.sample(linearClamp, uv).rgb + glow.sample(linearClamp, uv).rgb * 0.6
        + wideGlow.sample(linearClamp, uv).rgb * 0.9;
    color = saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));
    float2 centered = in.uv - 0.5;
    color *= 1 - dot(centered, centered) * 0.7;
    return float4(pow(color, 1 / 2.2), 1);
}
