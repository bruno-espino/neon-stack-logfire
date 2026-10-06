#include <metal_stdlib>
using namespace metal;

// Shared with MazeUniforms in LogRoll.swift. Keep the field order identical.
struct MazeUniforms {
    float4x4 viewProjection;  // perspective camera above and behind the log
    float4 eye;               // xyz camera position, w seconds since start
    float4 right;             // xyz camera right, for flame billboards
    float4 up;                // xyz camera up
    float4 step;              // x simulation step in seconds, y particle count, z intensity, w size scale
    float4 log;               // x, z, roll in radians, 1 when the log lies along x
    float4 fire;              // x maze clock in ticks, y cycle ticks, z burn ticks, w warning ticks
    float4 maze;              // x size, y exit x, z exit z, w jet count
    float4 state;             // x 1 after the log catches fire (or is put out in a water maze)
    float4 world;             // x log heat 0 to 1, y 1 in water mazes, z maze turn in quarter turns
};

// Jets are x, z, phase in ticks, unused. Walls are x, z, height, random seed, or for gates, -1 minus the gate's facing.
constant uint maxJets = 64;
constant float logRadius = 0.3;
constant float logHalfLength = 0.46;
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

/// Where a jet is in the shared rhythm, in ticks. Matches FireJet.moment in LogRollEngine.swift.
static float moment(float4 jet, constant MazeUniforms &u) { return fmod(u.fire.x + jet.z, u.fire.y); }
/// 0 when cold, a faint glow while warming, 1 at full flame with a short fade at both ends.
static float heat(float4 jet, constant MazeUniforms &u) {
    float t = moment(jet, u);
    if (t < u.fire.z) return smoothstep(0.0, 10.0, t) * smoothstep(u.fire.z, u.fire.z - 25, t);
    return t >= u.fire.y - u.fire.w ? 0.12 * (t - (u.fire.y - u.fire.w)) / u.fire.w : 0;
}

static bool watery(constant MazeUniforms &u) { return u.world.y > 0.5; }
static bool crashed(constant MazeUniforms &u) { return u.state.x > 0.5; }

/// How far a gate is from open, 0 when the maze faces its way and 1 or more a quarter turn off.
static float gateDistance(float facing, constant MazeUniforms &u) {
    return 2 - abs(fmod(u.world.z - facing + 8, 4.0) - 2);
}

// MARK: Fire and water particles

/// Which source a particle belongs to: 0 a floor jet, 1 the log, 2 the fire pit at the end of a water maze.
/// The hotter the log, the more particles burn on it.
static uint role(uint id, constant MazeUniforms &u) {
    float heat = u.world.x;
    if (crashed(u)) { if (!watery(u) && id % 3 == 0) return 1; }
    else if (heat > 0) {
        uint every = heat >= 1 ? 4 : heat >= 0.75 ? 12 : heat >= 0.5 ? 32 : 96;
        if (id % every == 1) return 1;
    }
    if (watery(u) && id % 24 == 2) return 2;
    return 0;
}

kernel void rollParticles(device float4 *particles [[buffer(0)]], constant MazeUniforms &u [[buffer(1)]],
                          constant float4 *jets [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= uint(u.step.y)) return;
    float4 p = particles[id * 2];       // xyz world position, w remaining life
    float4 v = particles[id * 2 + 1];   // xyz velocity, w how fast life drains
    float dt = u.step.x, time = u.eye.w;
    uint jetCount = min(uint(u.maze.w), maxJets);
    uint kind = role(id, u);
    bool spray = kind == 0 && watery(u);
    float3 source = kind == 1 ? float3(u.log.x, 0.3, u.log.y) : float3(u.maze.y, 0.05, u.maze.z);
    float t = 0;
    if (kind == 0 && jetCount > 0) {
        float4 jet = jets[id % jetCount];
        source = float3(jet.x, 0.05, jet.y);
        t = moment(jet, u);
    }
    bool burning = kind == 0 && jetCount > 0 && t < u.fire.z;
    bool warming = kind == 0 && jetCount > 0 && t >= u.fire.y - u.fire.w;
    // A log that is only warm smoulders with a few slow embers. Once ablaze, it burns properly.
    float logLift = crashed(u) || u.world.x >= 1 ? 1.6 : 0.5;
    p.w -= dt * v.w;
    if (p.w <= 0) {
        uint seed = id * 9781u + uint(time * 240.0) * 6271u;
        if (kind != 0 || burning || (warming && unit(seed) < 0.03)) {
            float lift = kind == 1 ? logLift : kind == 2 ? 2.4 : spray ? (burning ? 4.6 : 1.2) : (burning ? 3.4 : 0.5);
            float spread = kind == 1 ? 0.5 : spray ? 0.35 : 0.7;
            p = float4(source + float3(unit(seed) - 0.5, unit(seed) * 0.1, unit(seed) - 0.5) * spread, 1);
            v = float4((unit(seed) - 0.5) * (spray ? 1.6 : 0.6), lift * (0.8 + unit(seed) * 0.8),
                       (unit(seed) - 0.5) * (spray ? 1.6 : 0.6), 1 / (0.5 + 0.6 * unit(seed)));
        } else {
            p.w = 0;
        }
    } else if (spray) {
        // Water arcs up and falls back, then splashes on the floor.
        v.y -= 9 * dt;
        v.xyz *= 1 - 0.6 * dt;
        p.xyz += v.xyz * dt;
        if (p.y < 0) { p.y = 0; v.y *= -0.3; v.xz *= 0.5; }
    } else {
        float3 q = p.xyz * 2.1 + float3(0, time * -1.8, 0);
        float3 swirl = float3(sin(q.y * 2.3 + q.z * 3.1 + time * 2.5), cos(q.z * 2.2 + q.x * 3.4 - time * 1.7),
                              sin(q.x * 2.7 + q.y * 2.6 + time * 2.1));
        float2 inward = (source.xz - p.xz) * 1.2;
        v.xyz += (swirl * 1.4 + float3(inward.x, 2.2, inward.y)) * dt;
        v.xyz *= 1 - 1.8 * dt;
        p.xyz += v.xyz * dt;
    }
    particles[id * 2] = p;
    particles[id * 2 + 1] = v;
}

struct ParticleOut { float4 position [[position]]; float2 corner; float3 color; };

vertex ParticleOut rollParticleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                      const device float4 *particles [[buffer(0)]],
                                      constant MazeUniforms &u [[buffer(1)]]) {
    float4 p = particles[iid * 2];
    ParticleOut out;
    out.corner = float2((vid & 1) ? 1 : -1, (vid & 2) ? 1 : -1);
    if (p.w <= 0) { out.position = float4(0, 0, 2, 1); out.color = 0; return out; }
    float life = saturate(p.w);
    uint kind = role(iid, u);
    bool spray = kind == 0 && watery(u);
    float size = (spray ? 0.05 + 0.07 * life : 0.04 + 0.11 * life) * u.step.w;
    float3 world = p.xyz + (u.right.xyz * out.corner.x + u.up.xyz * out.corner.y) * size;
    out.position = u.viewProjection * float4(world, 1);
    float3 hot = float3(1.0, 0.55, 0.14), warm = float3(0.9, 0.16, 0.01), cool = float3(0.3, 0.02, 0.005);
    float3 tint = life > 0.5 ? mix(warm, hot, (life - 0.5) * 2) : mix(cool, warm, life * 2);
    if (spray) tint = mix(float3(0.1, 0.4, 1.2), float3(0.9, 1.3, 1.8), life) * 1.6;
    // Embers on a log that is only warm are dimmer than real flames.
    float strength = kind == 1 && !crashed(u) ? 0.3 + 0.7 * u.world.x * u.world.x : 1;
    out.color = tint * (0.3 + 1.4 * life * life) * life * u.step.z * strength;
    return out;
}

fragment half4 rollParticleFragment(ParticleOut in [[stage_in]]) {
    float falloff = max(0.0, exp(-dot(in.corner, in.corner) * 3.5) - exp(-3.5));
    return half4(half3(in.color * falloff), 0);
}

// MARK: Lighting shared by the floor, walls, and log

static float3 mazeLight(float3 position, float3 normal, constant float4 *jets, constant MazeUniforms &u) {
    float time = u.eye.w;
    float3 light = float3(0.05, 0.05, 0.08);
    uint jetCount = min(uint(u.maze.w), maxJets);
    bool water = watery(u);
    float3 jetColor = water ? float3(0.25, 0.55, 1.0) : float3(1.0, 0.45, 0.12);
    for (uint i = 0; i < jetCount; ++i) {
        float strength = heat(jets[i], u);
        if (strength <= 0) continue;
        float flicker = 0.85 + 0.15 * sin(time * 13 + float(i) * 1.7) * sin(time * 7.3 + float(i));
        float3 toLight = float3(jets[i].x, 0.8, jets[i].y) - position;
        float facing = max(dot(normal, normalize(toLight)), 0.0) * 0.8 + 0.2;
        light += jetColor * facing * flicker * strength * 2.4 / (1 + dot(toLight, toLight) * 0.9);
    }
    // The exit is a cool pool in fire mazes and a fire pit in water mazes.
    float3 toPool = float3(u.maze.y, 0.5, u.maze.z) - position;
    float3 poolColor = water ? float3(1.0, 0.45, 0.12) * (0.9 + 0.1 * sin(time * 11)) : float3(0.2, 0.7, 1.0);
    light += poolColor * (max(dot(normal, normalize(toPool)), 0.0) * 0.8 + 0.2) * 1.4 / (1 + dot(toPool, toPool) * 0.6);
    // A burning log lights its surroundings.
    float glow = crashed(u) ? (water ? 0 : 2) : 1.6 * smoothstep(0.5, 1.0, u.world.x);
    if (glow > 0) {
        float3 toLog = float3(u.log.x, 0.5, u.log.y) - position;
        light += float3(1.0, 0.4, 0.1) * glow * (0.9 + 0.1 * sin(time * 17)) / (1 + dot(toLog, toLog));
    }
    return light;
}

// MARK: Sky, floor, walls, and log

struct FullscreenOut { float4 position [[position]]; float2 uv; };

vertex FullscreenOut rollFullscreen(uint vid [[vertex_id]]) {
    float2 point = float2((vid << 1) & 2, vid & 2) * 2 - 1;
    return {float4(point, 0, 1), float2(point.x * 0.5 + 0.5, 0.5 - point.y * 0.5)};
}

fragment float4 rollSky(FullscreenOut in [[stage_in]], constant MazeUniforms &u [[buffer(0)]]) {
    float3 color = watery(u) ? mix(float3(0.01, 0.03, 0.07), float3(0.003, 0.006, 0.02), in.uv.y)
                             : mix(float3(0.06, 0.025, 0.03), float3(0.005, 0.006, 0.02), in.uv.y);
    float2 cell = floor(in.uv * float2(90, 50));
    float star = step(0.992, hash2(cell)) * smoothstep(0.4, 0.0, length(fract(in.uv * float2(90, 50)) - 0.5));
    color += star * float3(1.0, 0.45, 0.15) * (0.3 + 0.3 * sin(u.eye.w * 3 + hash2(cell + 7) * 40));
    return float4(color, 1);
}

struct SurfaceOut { float4 position [[position]]; float3 world; float3 normal; float3 local; float gate; };

vertex SurfaceOut rollFloorVertex(uint vid [[vertex_id]], constant MazeUniforms &u [[buffer(0)]]) {
    const float2 corners[6] = {float2(0, 0), float2(1, 0), float2(1, 1), float2(0, 0), float2(1, 1), float2(0, 1)};
    float margin = 30;
    float2 xz = -0.5 - margin + corners[vid] * (u.maze.x + margin * 2);
    float3 world = float3(xz.x, 0, xz.y);
    return {u.viewProjection * float4(world, 1), world, float3(0, 1, 0), float3(0)};
}

fragment float4 rollFloor(SurfaceOut in [[stage_in]], constant MazeUniforms &u [[buffer(0)]],
                          constant float4 *jets [[buffer(2)]]) {
    float2 p = in.world.xz, cell = floor(p + 0.5), f = p + 0.5 - cell;
    float grout = smoothstep(0.03, 0.06, min(min(f.x, 1 - f.x), min(f.y, 1 - f.y)));
    float grain = noise2(p * 6) * 0.5 + noise2(p * 23) * 0.25;
    float3 albedo = mix(float3(0.05, 0.045, 0.045), float3(0.16, 0.14, 0.13), grain) * (0.35 + 0.65 * grout);
    if (watery(u)) albedo *= float3(0.75, 0.9, 1.15);
    float3 color = albedo * mazeLight(in.world, float3(0, 1, 0), jets, u);
    float2 local = p - cell;
    float radius = length(local);
    // Fire grates: dark bars over a pit that glows red while warming and white-hot while burning.
    uint jetCount = min(uint(u.maze.w), maxJets);
    for (uint i = 0; i < jetCount; ++i) {
        if (any(jets[i].xy != cell)) continue;
        float t = moment(jets[i], u);
        bool burning = t < u.fire.z;
        float warning = t >= u.fire.y - u.fire.w ? (t - (u.fire.y - u.fire.w)) / u.fire.w : 0;
        float pit = smoothstep(0.4, 0.36, radius);
        float bars = smoothstep(0.35, 0.5, abs(fract(local.x * 5) - 0.5) * 2);
        float blink = 0.6 + 0.4 * sin(u.eye.w * 25);
        float3 glow = watery(u) ? (burning ? float3(0.5, 1.3, 3.0) : float3(0.05, 0.3, 1.4) * warning * blink)
                                : (burning ? float3(3.0, 1.1, 0.25) : float3(1.2, 0.08, 0.02) * warning * blink);
        color = mix(color, float3(0.02, 0.015, 0.015) + glow * (1 - bars), pit);
        color += (watery(u) ? float3(0.05, 0.2, 0.6) : float3(0.5, 0.06, 0.01)) * smoothstep(0.45, 0.4, radius) * smoothstep(0.34, 0.4, radius) * (0.4 + warning);
    }
    // The exit: a cool pool that ripples, or in water mazes a fire pit of glowing coals.
    if (all(cell == u.maze.yz)) {
        float pool = smoothstep(0.42, 0.38, radius);
        float edge = smoothstep(0.46, 0.42, radius) * smoothstep(0.36, 0.42, radius) * 2;
        if (watery(u)) {
            float coals = noise2(local * 14 + float2(0, u.eye.w * 0.6));
            color = mix(color, float3(1.6, 0.45, 0.08) * (0.4 + 0.8 * coals), pool);
            color += float3(1.2, 0.4, 0.08) * edge;
        } else {
            float ripple = 0.5 + 0.5 * sin(radius * 40 - u.eye.w * 4);
            color = mix(color, float3(0.1, 0.55, 0.9) * (0.8 + 0.6 * ripple), pool);
            color += float3(0.3, 0.9, 1.2) * edge;
        }
    }
    // Outside the maze the ground falls away into darkness.
    float2 outside = max(max(-0.5 - p, p - (u.maze.x - 0.5)), 0);
    color *= exp(-length(outside) * 3);
    return float4(color, 1);
}

vertex SurfaceOut rollWallVertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant MazeUniforms &u [[buffer(0)]],
                                 const device float4 *walls [[buffer(1)]]) {
    float4 wall = walls[iid];
    // Gates sink into the floor when the maze turns their way.
    float gate = wall.w < 0 ? -wall.w : 0;
    if (gate > 0) wall.z = mix(0.03, 0.55, smoothstep(0.0, 0.5, gateDistance(gate - 1, u)));
    const float2 corners[6] = {float2(-1, -1), float2(1, -1), float2(1, 1), float2(-1, -1), float2(1, 1), float2(-1, 1)};
    uint face = vid / 6, axis = face / 2;
    float side = (face & 1) ? 1 : -1;
    float2 c = corners[vid % 6];
    float3 local = axis == 0 ? float3(side, c.x, c.y) : axis == 1 ? float3(c.x, side, c.y) : float3(c.x, c.y, side);
    float3 normal = axis == 0 ? float3(side, 0, 0) : axis == 1 ? float3(0, side, 0) : float3(0, 0, side);
    float3 world = float3(wall.x + local.x * 0.5, (local.y * 0.5 + 0.5) * wall.z, wall.y + local.z * 0.5);
    SurfaceOut out;
    out.position = u.viewProjection * float4(world, 1);
    out.world = world;
    out.normal = normal;
    out.local = float3(axis == 1 ? world.xz : float2(axis == 0 ? world.z : world.x, world.y), abs(wall.w));
    out.gate = gate;
    return out;
}

fragment float4 rollWall(SurfaceOut in [[stage_in]], constant MazeUniforms &u [[buffer(0)]],
                         constant float4 *jets [[buffer(2)]]) {
    float3 normal = normalize(in.normal);
    if (in.gate > 0.5) {
        // A bronze gate with an arrow on top. The arrow glows blue when the gate is open, amber when shut.
        float facing = round(in.gate) - 1;
        bool open = gateDistance(facing, u) < 0.05;
        float3 accent = open ? float3(0.3, 1.0, 1.6) : float3(1.4, 0.6, 0.12);
        float3 metal = float3(0.22, 0.16, 0.09) * (mazeLight(in.world, normal, jets, u) + 0.3);
        if (normal.y < 0.5) {
            float band = smoothstep(0.04, 0.0, abs(in.world.y - 0.12));
            return float4(metal + accent * band * 0.8, 1);
        }
        float angle = facing * 1.5707963;
        float2 forward = float2(sin(angle), -cos(angle)), side = float2(-forward.y, forward.x);
        float2 q = in.world.xz - round(in.world.xz);
        float along = dot(q, forward), across = abs(dot(q, side));
        float head = step(0.0, along) * step(along, 0.34) * step(across, (0.34 - along) * 0.85);
        float shaft = step(-0.3, along) * step(along, 0.0) * step(across, 0.07);
        float2 edge = abs(q);
        float rim = smoothstep(0.42, 0.48, max(edge.x, edge.y));
        return float4(metal + accent * max(head, shaft) * 1.5 + accent * rim * 0.3, 1);
    }
    float2 p = in.local.xy * 3 + in.local.z * 17;
    float grain = noise2(p * 2.5) * 0.6 + noise2(p * 9) * 0.4;
    bool top = normal.y > 0.5;
    // Tops are pale so the maze reads at a glance. Sides are dark basalt.
    float3 albedo = top ? mix(float3(0.2, 0.15, 0.13), float3(0.3, 0.24, 0.2), grain)
                        : mix(float3(0.05, 0.04, 0.04), float3(0.16, 0.13, 0.11), grain);
    float cracks = smoothstep(0.06, 0.0, abs(noise2(p * 1.4 + 3) - 0.5));
    float pulse = 0.6 + 0.4 * sin(u.eye.w * 2 + in.local.z * 20);
    // Embers glow in the cracks near the ground, where the heat collects.
    float low = top ? 0 : smoothstep(0.5, 0.0, in.world.y);
    float3 color = albedo * (mazeLight(in.world, normal, jets, u) + (top ? 0.25 : 0.04))
        + float3(1.0, 0.25, 0.03) * cracks * pulse * low * 0.8;
    // A faint rim on the top edges so walls read as solid blocks from above.
    float2 edge = abs(fract(in.world.xz + 0.5) - 0.5);
    if (top) color += float3(0.3, 0.15, 0.08) * smoothstep(0.45, 0.5, max(edge.x, edge.y));
    return float4(color, 1);
}

vertex SurfaceOut rollLogVertex(uint vid [[vertex_id]], constant MazeUniforms &u [[buffer(0)]]) {
    const uint segments = 32;
    float along, angle, radial = 1, cap = 0;
    if (vid < segments * 6) {
        uint corner = vid % 6;
        uint segment = vid / 6 + ((corner == 1 || corner == 2 || corner == 4) ? 1 : 0);
        along = (corner == 2 || corner == 4 || corner == 5) ? logHalfLength : -logHalfLength;
        angle = 6.2831853 * float(segment) / float(segments);
    } else {
        uint index = vid - segments * 6;
        uint corner = index % 3;
        cap = index / (segments * 3) == 0 ? -1 : 1;
        along = cap * logHalfLength;
        angle = 6.2831853 * float(index % (segments * 3) / 3 + (corner == 2 ? 1 : 0)) / float(segments);
        radial = corner == 0 ? 0 : 1;
    }
    // The bark turns as the log rolls, so it looks like it grips the floor.
    float spun = angle + u.log.z;
    float bumps = 1 + 0.05 * sin(angle * 7 + along * 3) * (cap == 0 ? 1 : 0);
    float2 ring = float2(sin(spun), cos(spun)) * logRadius * radial * bumps;
    bool alongX = u.log.w > 0.5;
    float3 offset = alongX ? float3(along, ring.y, ring.x) : float3(ring.x, ring.y, along);
    float3 normal = cap != 0 ? (alongX ? float3(cap, 0, 0) : float3(0, 0, cap))
                             : (alongX ? float3(0, cos(spun), sin(spun)) : float3(sin(spun), cos(spun), 0));
    float3 world = float3(u.log.x, logRadius, u.log.y) + offset;
    float2 face = float2(cos(angle), sin(angle)) * radial * logRadius;
    return {u.viewProjection * float4(world, 1), world, normal, cap == 0 ? float3(along, angle, -1) : float3(face, 1)};
}

fragment float4 rollLog(SurfaceOut in [[stage_in]], constant MazeUniforms &u [[buffer(0)]],
                        constant float4 *jets [[buffer(2)]]) {
    float3 normal = normalize(in.normal);
    float3 albedo;
    if (in.local.z < 0) {
        float groove = noise2(float2(in.local.y * 9, in.local.x * 6));
        albedo = mix(float3(0.16, 0.09, 0.05), float3(0.42, 0.27, 0.14), smoothstep(0.25, 0.75, groove));
    } else {
        float2 face = in.local.xy;
        float rings = fract(length(face) * 30 + noise2(face * 14) * 0.6);
        albedo = mix(float3(0.75, 0.55, 0.33), float3(0.5, 0.32, 0.17), smoothstep(0.6, 0.9, rings));
    }
    // A soft key light from the camera side keeps the log readable against the dark floor.
    float key = max(dot(normal, normalize(u.eye.xyz - in.world)), 0.0) * 0.5;
    // Each maze chars the bark a little more, and glowing cracks spread until the whole log is ablaze.
    float heat = u.world.x;
    albedo = mix(albedo, float3(0.035, 0.03, 0.028), smoothstep(0.0, 0.8, heat) * 0.9);
    float3 color = albedo * (float3(0.3, 0.28, 0.3) + key + mazeLight(in.world, normal, jets, u));
    float burn = crashed(u) ? (watery(u) ? 0 : 1) : smoothstep(0.1, 1.0, heat);
    if (burn > 0) {
        float embers = smoothstep(0.85 - 0.35 * burn, 0.9, noise2(float2(in.local.x * 8, in.local.y * 4) + u.eye.w * 1.5));
        color += float3(1.0, 0.32, 0.05) * embers * burn * (2.5 + sin(u.eye.w * 17));
    }
    return float4(color, 1);
}

// MARK: Glow and final image

fragment half4 rollBrightPass(FullscreenOut in [[stage_in]], texture2d<half> scene [[texture(0)]]) {
    half3 color = scene.sample(linearClamp, in.uv).rgb;
    return half4(max(color - 0.9h, 0.0h), 1);
}

fragment half4 rollCopy(FullscreenOut in [[stage_in]], texture2d<half> source [[texture(0)]]) {
    return source.sample(linearClamp, in.uv);
}

fragment half4 rollBlur(FullscreenOut in [[stage_in]], texture2d<half> source [[texture(0)]],
                        constant float2 &direction [[buffer(0)]]) {
    const float weights[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};
    half3 color = source.sample(linearClamp, in.uv).rgb * weights[0];
    for (int i = 1; i < 5; ++i) {
        color += source.sample(linearClamp, in.uv + direction * float(i) * 1.5).rgb * weights[i];
        color += source.sample(linearClamp, in.uv - direction * float(i) * 1.5).rgb * weights[i];
    }
    return half4(color, 1);
}

fragment float4 rollComposite(FullscreenOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                              texture2d<float> glow [[texture(1)]], texture2d<float> wideGlow [[texture(2)]],
                              constant MazeUniforms &u [[buffer(0)]]) {
    float heat = saturate(dot(wideGlow.sample(linearClamp, in.uv).rgb, float3(0.3, 0.5, 0.2)) * 1.5);
    float2 shimmer = float2(noise2(in.uv * float2(60, 30) + float2(0, u.eye.w * 3)),
                            noise2(in.uv * float2(60, 30) + float2(17, u.eye.w * 3.4))) - 0.5;
    float2 uv = in.uv + shimmer * heat * 0.004;
    float3 color = scene.sample(linearClamp, uv).rgb + glow.sample(linearClamp, uv).rgb * 0.6
        + wideGlow.sample(linearClamp, uv).rgb * 0.9;
    color = saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));
    float2 centered = in.uv - 0.5;
    color *= 1 - dot(centered, centered) * 0.7;
    return float4(pow(color, 1 / 2.2), 1);
}
