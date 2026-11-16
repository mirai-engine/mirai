// The slots of what the probes keep of their rays (render.Probe_Hits,
// probe_hits.slang). Each probe has its own while they all fit the memory of
// the hits; past it, a probe holds one of the two its index falls on, which
// it takes when it is chosen (ddgi_select.comp) if it is free or its probe was
// not chosen for a while. A probe without a slot traces all its rays.
#ifndef MIRAI_PROBE_SLOTS_SLANG
#define MIRAI_PROBE_SLOTS_SLANG
#include "scene.slang"

// The words of a slot (render.Probe_Slot): the probe that holds it, plus one
// (0: none), and the update until which a probe that is chosen leaves it to it.
#define PROBE_SLOT_WORDS 2u
#ifdef PROBE_SLOTS_WRITABLE
[[vk::binding(SLOT_PASS4, 0)]] RWStructuredBuffer<uint> probe_slots : register(MIRAI_REGISTER(u, SLOT_PASS4), space0);
#else
[[vk::binding(SLOT_PASS4, 0)]] StructuredBuffer<uint> probe_slots : register(MIRAI_REGISTER(t, SLOT_PASS4), space0);
#endif

// The two slots, of `slots`, a probe may hold.
uint2 probe_slots_of(uint index, uint slots) {
    if (slots >= probe_cascade_size() * probe_cascades()) return uint2(index, index);
    return uint2(hash_u32(index), hash_u32(index ^ 0x9E3779B9u)) % max(slots, 1u);
}
// The one it holds; INVALID: none.
uint probe_slot_held(uint index, uint slots) {
    if (slots == 0u) return INVALID;
    uint2 its = probe_slots_of(index, slots);
    if (probe_slots[its.x * PROBE_SLOT_WORDS] == index + 1u) return its.x;
    if (probe_slots[its.y * PROBE_SLOT_WORDS] == index + 1u) return its.y;
    return INVALID;
}

#endif
