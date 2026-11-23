#ifndef MIRAI_PARTICLE_WORK_SLANG
#define MIRAI_PARTICLE_WORK_SLANG
#define PARTICLE_WORK_ROW 32768u

// One prefix per emitter, in workgroups. A dispatch group never mixes emitters.
struct Particle_Work {
    uint slot;
    uint item;
};

Particle_Work particle_work(uint3 group_id, uint lane, uint count) {
    uint group = group_id.x + PARTICLE_WORK_ROW * group_id.y;
    Particle_Work work;
    work.slot = INVALID;
    work.item = 0u;
    if (group >= particle_queue[WORK_AT / 4u + 3u]) return work;
    uint first = 0u, slot = 0u;
    if (WaveIsFirstLane()) {
        uint low = 0u, high = count;
        while (low < high) {
            uint middle = (low + high) / 2u;
            if (group < particle_queue[WORK_AT / 4u + 4u + middle * 2u]) high = middle;
            else low = middle + 1u;
        }
        first = low == 0u ? 0u : particle_queue[WORK_AT / 4u + 4u + (low - 1u) * 2u];
        slot = particle_queue[WORK_AT / 4u + 5u + low * 2u];
    }
    work.slot = WaveReadLaneFirst(slot);
    work.item = (group - WaveReadLaneFirst(first)) * 64u + lane;
    return work;
}

uint particle_birth_step(float age, float4 frame_step) {
    float born = frame_step.x - age;
    return born <= 0.0 ? 0u : min(uint(born / max(frame_step.y, 1e-6)), uint(frame_step.z) - 1u);
}

float2 particle_birth_window(uint slot, float frame_dt) {
    float age = asfloat(particle_emitters[slot].data.z);
    float span = (particle_emitters[slot].range.w & PARTICLE_FLAG_RESET) != 0u ? max(age, frame_dt) : frame_dt;
    float active = clamp(particle_emitters[slot].birth_limit - (age - span), 0.0, span);
    return float2(span, active);
}

Particle_Birth particle_channel_item(uint slot, uint ordinal) {
    return particle_birth_at(particle_frame_births() + particle_emitters[slot].frame.y + ordinal * PARTICLE_BIRTH_BYTES);
}

struct Particle_Births {
    uint slot;
    uint count;
    uint per;  // zero for channel records
    float age;
    float spacing;
};

float particle_age_at(Particle_Births births, uint ordinal) {
    if (births.per == 0u) return particle_channel_item(births.slot, ordinal).age;
    return births.age - float(ordinal / births.per) * births.spacing;
}

uint particle_first_birth(Particle_Births births, uint step, float4 frame_step) {
    uint low = 0u, high = births.count;
    while (low < high) {
        uint middle = (low + high) / 2u;
        if (particle_birth_step(particle_age_at(births, middle), frame_step) < step) low = middle + 1u;
        else high = middle;
    }
    return low;
}

uint2 particle_birth_span(Particle_Births births, uint step, float4 frame_step) {
    if (births.count == 0u || frame_step.z <= 1.0) return uint2(0u, births.count);
    uint first = step == 0u ? 0u : particle_first_birth(births, step, frame_step);
    uint end = step + 1u >= uint(frame_step.z) ? births.count : particle_first_birth(births, step + 1u, frame_step);
    return uint2(first, end - first);
}

uint2 particle_channel_span(uint slot, uint step) {
    Particle_Births births = {slot, particle_emitters[slot].frame.z, 0u, 0.0, 0.0};
    return particle_birth_span(births, step, particle_frame_step());
}

// Ordinals are dense within the step; the seeds still use the original birth indices.
// ribbon: the one the group of the birth joins.
bool particle_spawn(uint slot, uint step, uint ordinal, out uint birth, out float age, out uint ribbon) {
    float4 frame_step = particle_frame_step();
    uint4 range = particle_emitters[slot].range;
    birth = 0u;
    age = 0.0;
    ribbon = 0u;
    if ((range.w & PARTICLE_FLAG_BIRTHS) != 0u) {
        uint count = particle_states[slot].births;
        float2 window = particle_birth_window(slot, frame_step.x);
        float spacing = window.y / float(max(count, 1u));
        Particle_Births births = {slot, count, 1u, window.x - spacing * 0.5, spacing};
        uint2 span = particle_birth_span(births, step, frame_step);
        if (ordinal == INVALID) { birth = span.y; return false; }
        if (ordinal >= span.y) return false;
        uint item = span.x + ordinal;
        birth = particle_states[slot].born - count + item;
        age = particle_age_at(births, item);
        return true;
    }
    uint remaining = range.z;
    for (uint g = 0u; g < particle_emitters[slot].random.w && remaining != 0u; g++) {
        uint4 spawn = particle_emitters[slot].spawns[g];
        float spacing = particle_emitters[slot].spacing[g / 4u][g % 4u];
        Particle_Births births = {slot, min(spawn.x, remaining), max(spawn.y, 1u), asfloat(spawn.w), spacing};
        remaining -= births.count;
        uint2 span = particle_birth_span(births, step, frame_step);
        if (ordinal == INVALID) { birth += span.y; continue; }
        if (ordinal < span.y) {
            uint item = span.x + ordinal;
            birth = spawn.z + item;
            age = particle_age_at(births, item);
            ribbon = particle_emitters[slot].ribbons[g / 4u][g % 4u];
            return true;
        }
        ordinal -= span.y;
    }
    return false;
}

#endif
