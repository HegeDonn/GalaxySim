// Click-only parallel picking. Gas is not a star; ignore it. Indices stay uint
// throughout (float loses identity above 16,777,216 particles).
struct StarPickCandidate { float distance; uint index; };
kernel void pickExplorerStar(device const Particle *particles [[buffer(0)]],
                             device const uint *aux [[buffer(1)]],
                             constant CameraUniforms &cam [[buffer(2)]],
                             constant RelativityUniforms &rel [[buffer(3)]],
                             constant uint &count [[buffer(4)]],
                             constant float4 &click [[buffer(5)]],
                             device StarPickCandidate *results [[buffer(6)]],
                             uint id [[thread_position_in_grid]],
                             uint lane [[thread_index_in_threadgroup]],
                             uint group [[threadgroup_position_in_grid]]) {
    threadgroup StarPickCandidate candidates[256];
    StarPickCandidate best = { INFINITY, 0xffffffffu };
    if (id < count && (aux[id] & 255u) != 3u) {
        float3 delta = particles[id].position.xyz - cam.cameraPos.xyz;
        float dist = length(delta);
        float probability = mix(cam.extra.w, 1.0f, 1.0f - smoothstep(10.0f, 30.0f, dist));
        float random = float(starHash(id) >> 8) / 16777216.0f;
        if (random < probability && dist > 1e-8f) {
            float3 direction = delta / dist;
            if (rel.params.x >= 0.5f)
                direction = relAberrateScaled(delta, rel.boost.xyz, rel.boost.w, rel.params.w);
            float4 clip = cam.viewProj * float4(cam.cameraPos.xyz + direction * dist, 1);
            if (clip.w > 0 && clip.z >= 0 && clip.z <= clip.w) {
                float2 screen = (clip.xy / clip.w * 0.5f + 0.5f) * cam.viewport.xy;
                float d = length(screen - click.xy);
                if (d <= click.z) best = {d, id};
            }
        }
    }
    candidates[lane] = best;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint width = 128; width > 0; width >>= 1) {
        if (lane < width) {
            StarPickCandidate other = candidates[lane + width];
            StarPickCandidate own = candidates[lane];
            if (other.distance < own.distance ||
                (other.distance == own.distance && other.index < own.index))
                candidates[lane] = other;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lane == 0) results[group] = candidates[0];
}

vertex PointOut explorerMarker(device const Particle *particles [[buffer(0)]],
                                constant CameraUniforms &cam [[buffer(1)]],
                                constant RelativityUniforms &rel [[buffer(2)]],
                                constant uint &index [[buffer(3)]]) {
    PointOut p = shadeParticle(particles[index], cam, rel);
    p.pointSize = 44;
    return p;
}
fragment float4 explorerMarkerFragment(PointOut in [[stage_in]], float2 uv [[point_coord]]) {
    float2 d = uv * 2 - 1;
    float r = length(d);
    float ring = smoothstep(0.66f, 0.71f, r) * (1 - smoothstep(0.77f, 0.82f, r));
    // Broken ring leaves the actual star visible; short compass ticks aid tracking.
    float ticks = (step(abs(d.x), 0.035f) + step(abs(d.y), 0.035f))
                * smoothstep(0.85f, 0.9f, r) * (1 - smoothstep(0.97f, 1.0f, r));
    float a = clamp(ring + ticks, 0.0f, 1.0f);
    return float4(float3(0.25f, 0.95f, 1.0f) * a, a);
}
