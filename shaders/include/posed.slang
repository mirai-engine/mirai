// Where the vertices of a skinned or deformed mesh are now
// (render.Gpu_Posed_Vertex, Posed_Vertex), read and written here alone: by
// geometry.slang, the skin and the stages that deform meshes. The includer
// declares vertex_words (SLOT_VERTICES) before it, and defines
// MIRAI_POSED_STORE when it writes them, with vertex_words writable.
#ifndef MIRAI_POSED_SLANG
#define MIRAI_POSED_SLANG
#include <shared_constants.slang>

// The vertex index of the run of posed vertices that starts at word `word`.
Posed_Vertex posed_load(uint word, uint index) {
    uint at = word + index * POSED_WORDS;
    Posed_Vertex v;
    v.position = asfloat(uint3(vertex_words[at], vertex_words[at + 1u], vertex_words[at + 2u]));
    v.normal = vertex_words[at + 3u];
    v.tangent = vertex_words[at + 4u];
    return v;
}

float3 posed_position(uint word, uint index) {
    uint at = word + index * POSED_WORDS;
    return asfloat(uint3(vertex_words[at], vertex_words[at + 1u], vertex_words[at + 2u]));
}

#ifdef MIRAI_POSED_STORE
void posed_store(uint word, uint index, Posed_Vertex v) {
    uint at = word + index * POSED_WORDS;
    vertex_words[at] = asuint(v.position.x);
    vertex_words[at + 1u] = asuint(v.position.y);
    vertex_words[at + 2u] = asuint(v.position.z);
    vertex_words[at + 3u] = v.normal;
    vertex_words[at + 4u] = v.tangent;
}
#endif
#endif
