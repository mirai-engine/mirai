#ifndef MIRAI_VFX_CONTRACT
#define MIRAI_VFX_CONTRACT
// The contract of a Vfx program: a source that declares `//! mirai vfx Name`
// and a namespace Name with
//
//   struct Parameters  the values of the emitter (.particle parameters), as
//                      surface programs take theirs
//   struct Attributes  what the program keeps of each particle between steps,
//                      at most 1024 bytes; it starts at zero
//   void initialize(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a)
//                      when the particle starts, after the values of its effect
//   void update(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a)
//                      every step, before the forces of the effect move it
//   void render(Mirai_Vfx_Context ctx, Parameters p, Mirai_Vfx_Particle particle, Attributes a, inout Mirai_Vfx_Visual visual)
//                      what it shows, every frame it is drawn
//
// A line `//! resource name kind` names a resource the program reads, which
// each emitter binds: in the namespace, name is its index for the functions
// below. surface: the triangles of a mesh, or of what an entity draws (a skin
// moves them). channel: the births a game gives the channel of its name in
// this frame. bones: the bones of a skinned mesh, from the joint of each
// parent bone to its own, as the skin is posed. grid: a grid of the world of
// that name (vfx.Particle_Grid), layers of four floats in each cell; one
// declared `//! resource name grid cleared` starts at zero each stage that
// writes it. emitter: the particles of another emitter, the entity the
// emitter binds by the name of the resource (vfx.Particle_Bindings). data,
// `//! resource name data words`: the data channel of the world of that name,
// entries of words words that programs append (mirai_vfx_data_append, then
// mirai_vfx_data_store); a frame reads what the programs appended in the
// frame before.
//
// A line `//! stage name over particles|grid [iterations N] [neighbors
// radius] [writes grid,grid]` names a stage, a function of the namespace that
// runs every step before update, in the order they are declared; writes names
// the grids it leaves besides the one it goes over (mirai_vfx_grid_write and
// the words of a grid), which take what it left after it. It runs iterations
// times, each seeing what the one before left (ctx.iteration says which):
//
//   void name(Mirai_Vfx_Context ctx, Parameters p, inout Mirai_Vfx_Particle particle, inout Attributes a)
//                      over the particles; with neighbors, those within the
//                      radius (mirai_vfx_neighbors)
//   void name(Mirai_Vfx_Cell cell, Parameters p)
//                      over the cells of a grid it declares: it reads the
//                      grid as the iteration or stage before left it and
//                      leaves the layers of its cell with mirai_vfx_grid_store
//
// A line `//! moves` says the program moves and ages its particles itself:
// the forces, collisions, spin and aging of the effect do not run, and a
// particle dies when update leaves its age at or past its lifetime.
//
// A line `//! births` says the program gives the births of its emitter, in
// place of those of its effect:
//
//   uint births(Mirai_Vfx_Context ctx, Parameters p)
//                      once a frame, how many particles the emitter starts
//                      in it (at most its capacity), spread over the frame;
//                      born counts those it started before
//
// A line `//! prepare` says the program prepares, once a frame for each
// emitter and before its births and steps, words its other functions read:
//
//   void prepare(Mirai_Vfx_Context ctx, Parameters p)
//                      stores them with mirai_vfx_state_store (at most 128
//                      words); the rest reads them with mirai_vfx_state_load
//
// Positions are in the world relative to the origin the renderer draws from
// (render/origin.odin), and so are the transform of the emitter (ctx.world)
// and the view (mirai_vfx_view): what needs the place of the world (a noise, a
// pattern) takes what the origin adds from frame.origin, in steps (origin.slang).
// Velocities are in the world. Attributes, words of the state of a program and
// entries of a data channel that keep a place keep it relative to the emitter
// or to another particle: the origin moves the positions of the pool, not them.
// Programs never own passes, buffers or native handles.
struct Mirai_Vfx_Context {
    float time;        // seconds of the world
    float delta_time;  // seconds this step moves the particle; 0 in initialize and render
    float3 origin;     // where the emitter is
    float3 axis;       // the +Y of the emitter in the world, where its shape faces
    uint emitter;      // which one: the functions of the contract find its resources through it
    float4 values;     // in initialize, those of the birth of a channel that started the particle; zero otherwise
    uint particle;     // in initialize, update, render and the stages over particles, which one; 0xFFFFFFFF otherwise
    float emitter_age; // seconds since the emitter started, at the end of the frame
    uint born;         // particles the emitter started before this frame
    uint spawned;      // in initialize, how many particles the emitter starts this frame; 0 otherwise
    uint birth;        // in initialize, which of the particles the emitter started it is (born and its order in the frame); 0xFFFFFFFF otherwise
    uint iteration;    // in a stage, which of its iterations runs; 0 otherwise
    float4 world[3];   // the transform of the emitter, its rows: its place relative to the origin
};
struct Mirai_Vfx_Particle {
    float3 position; float age;
    float3 velocity; float lifetime;
    float size; float rotation; float spin; uint seed;
    float4 color;      // linear rgba it started with; the effect multiplies it over its life
};
struct Mirai_Vfx_Visual {
    float4 color;      // linear rgba, intensity included
    float size;        // metres across
    float frame;       // of the flipbook
    // What a sprite gives the Surface program of its material
    // (Mirai_Surface_Context.particle_data): data[i] counts where bit i of
    // given is set. Neither starts set.
    float4 data[4];
    uint given;
    float random;      // 0 to 1, what the material reads (Mirai_Surface_Context.particle_random); it starts from the seed of the particle
};
// A point of a surface: where it is in the world, its normal, how fast it
// moves, its uv, and the triangle and barycentrics (of its second and third
// corners) that find it again as the surface moves: the triangle as a sample
// gives it, the place of the triangle among the clusters of level 0 of the
// mesh, not its order in the mesh as imported. valid is false while the
// resource has no surface.
struct Mirai_Vfx_Surface {
    float3 position;
    float3 normal;
    float3 velocity;   // m/s
    float2 uv;
    uint triangle;
    float2 barycentric;
    bool valid;
};
// A point of a bone: where it is in the world, the way the bone goes (from
// the joint of its parent to its own), how fast it moves, and the bone and
// the share of it along it (0 at the joint of its parent) that find it again
// as the skin moves. valid is false while the resource has no bones.
struct Mirai_Vfx_Bone {
    float3 position;
    float3 axis;
    float3 velocity;   // m/s
    uint bone;
    float along;
    bool valid;
};
// A grid resource: its cells (one along an axis that is flat), the size of a
// cell, and the cell of the world (a position over the size of a cell) where
// its region starts: the region follows the entity of the grid by whole
// cells. valid is false while the resource has no grid.
struct Mirai_Vfx_Grid {
    int3 cells;
    float cell_size;   // metres
    int3 first;
    uint layers;
    float3 corner;     // the lowest corner of its first cell, relative to the origin of the frame
    bool valid;
};
// A cell a stage over a grid goes over: the context of its emitter, the
// resource of the grid, the cell in the world and where its middle is.
struct Mirai_Vfx_Cell {
    Mirai_Vfx_Context ctx;
    uint grid;
    int3 index;
    float3 position;
};
// A particle of the emitter near a point, in a stage with neighbors: where
// it is and how fast, how far, which one, and the first four words of its
// Attributes as floats.
struct Mirai_Vfx_Neighbor {
    float3 position; float distance;
    float3 velocity; uint particle;
    float4 values;
};
// A walk over the neighbors of a point (mirai_vfx_neighbors and
// mirai_vfx_neighbor_next): where it is among the cells around the point.
struct Mirai_Vfx_Neighbors {
    float3 position; float radius;
    int3 cell; uint around;
    uint at; uint end; uint emitter; uint particle;
};
// What a ray met in the scene: whether it met something, how far along the
// ray, the normal there towards where the ray came from, and whether it met
// the back of a face: it started inside a closed mesh.
struct Mirai_Vfx_Hit {
    bool hit;
    float distance;
    float3 normal;
    bool inside;
};
// The view the particles are simulated in: the first view of the window.
struct Mirai_Vfx_View {
    float3 position;
    float3 forward;
    float4x4 view;
    float4x4 projection;
    float4x4 view_projection;
    float4x4 inverse_view_projection;
    float2 resolution; // pixels
    float near;
    float far;
};
// A birth a game gave a channel: where and how fast, the color and size it
// gives its particles, how many it asked for and its values.
struct Mirai_Vfx_Birth {
    float3 position;
    float3 velocity;
    float4 color;
    float size;
    uint count;
    float4 values;
};
// A number from 0 to 1 that changes seed.
float mirai_vfx_random(inout uint seed) {
    seed = seed * 747796405u + 2891336453u;
    uint word = ((seed >> ((seed >> 28u) + 4u)) ^ seed) * 277803737u;
    return float((word >> 22u) ^ word) * (1.0 / 4294967296.0);
}
// A texture parameter at uv, at a level of its mips. A point of a surface
// resource chosen by area with seed, and the point of a triangle of it at
// barycentrics, as it is this frame. A point of a bones resource chosen by
// length with seed, and the point of a bone of it at along, as it is this
// frame. A grid: what it is; a layer of a cell as the stage before left it
// (zero outside its region; an axis of one cell takes every index), and at a
// point between its cells; what the particles of the step splatted into a
// cell; the layer the stage leaves in its cell; and a value spread over the
// cells around a point by how near they are. The neighbors of a point in a
// stage with neighbors, the particle itself left out: start a walk, then
// take the next one while there is one. The first opaque surface of the
// scene a ray meets from origin along direction within distance, as the
// renderer traces it this frame (moving bodies too): in initialize, update
// and the stages; render meets nothing.
//
// Another emitter (a resource of kind emitter): the slots of its range, the
// particles it drew last frame and the slot of the i-th of them, a particle
// of a slot (false when it is not alive) and a word of its Attributes; the
// particles it started before this frame and in it, and of the one it
// started as its birth-th (counting from 0) the seed it has or will have and
// its slot while it is alive (-1 otherwise). The id of the particle of ctx: its slot in its range and its seed, which no
// other particle of the emitter alive with it has. The words of a cell of a
// grid (4 a layer): loaded from what the stage before left or from what this
// one leaves, stored, and added to or compared at once with other threads in
// what this one leaves; a layer of what this one leaves, loaded and written.
// The view, and its depth (linear, 0 where nothing was drawn) and normal at
// a point of its image (uv from the top left), in initialize and update.
#ifdef MIRAI_VFX_REFLECTION
float4 mirai_vfx_texture(uint index, float2 uv, float level) { return float4(1.0); }
Mirai_Vfx_Surface mirai_vfx_surface_sample(Mirai_Vfx_Context ctx, uint resource, inout uint seed) { return (Mirai_Vfx_Surface)0; }
Mirai_Vfx_Surface mirai_vfx_surface_at(Mirai_Vfx_Context ctx, uint resource, uint triangle, float2 barycentric) { return (Mirai_Vfx_Surface)0; }
uint mirai_vfx_channel_count(Mirai_Vfx_Context ctx, uint resource) { return 0u; }
Mirai_Vfx_Birth mirai_vfx_channel_birth(Mirai_Vfx_Context ctx, uint resource, uint index) { return (Mirai_Vfx_Birth)0; }
Mirai_Vfx_Bone mirai_vfx_bone_sample(Mirai_Vfx_Context ctx, uint resource, inout uint seed) { return (Mirai_Vfx_Bone)0; }
Mirai_Vfx_Bone mirai_vfx_bone_at(Mirai_Vfx_Context ctx, uint resource, uint bone, float along) { return (Mirai_Vfx_Bone)0; }
Mirai_Vfx_Grid mirai_vfx_grid(Mirai_Vfx_Context ctx, uint resource) { return (Mirai_Vfx_Grid)0; }
float4 mirai_vfx_grid_load(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer) { return float4(0.0); }
float4 mirai_vfx_grid_sample(Mirai_Vfx_Context ctx, uint resource, float3 position, uint layer) { return float4(0.0); }
float4 mirai_vfx_grid_splatted(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer) { return float4(0.0); }
void mirai_vfx_grid_store(Mirai_Vfx_Cell cell, uint layer, float4 value) {}
void mirai_vfx_grid_splat(Mirai_Vfx_Context ctx, uint resource, float3 position, uint layer, float4 value) {}
Mirai_Vfx_Neighbors mirai_vfx_neighbors(Mirai_Vfx_Context ctx, float3 position) { return (Mirai_Vfx_Neighbors)0; }
bool mirai_vfx_neighbor_next(inout Mirai_Vfx_Neighbors walk, out Mirai_Vfx_Neighbor neighbor) { neighbor = (Mirai_Vfx_Neighbor)0; return false; }
Mirai_Vfx_Hit mirai_vfx_trace(Mirai_Vfx_Context ctx, float3 origin, float3 direction, float distance) { return (Mirai_Vfx_Hit)0; }
uint mirai_vfx_emitter_capacity(Mirai_Vfx_Context ctx, uint resource) { return 0u; }
uint mirai_vfx_emitter_alive(Mirai_Vfx_Context ctx, uint resource) { return 0u; }
uint mirai_vfx_emitter_drawn(Mirai_Vfx_Context ctx, uint resource, uint i) { return 0u; }
bool mirai_vfx_emitter_particle(Mirai_Vfx_Context ctx, uint resource, uint slot, out Mirai_Vfx_Particle value) { value = (Mirai_Vfx_Particle)0; return false; }
uint mirai_vfx_emitter_word(Mirai_Vfx_Context ctx, uint resource, uint slot, uint word) { return 0u; }
uint2 mirai_vfx_emitter_births(Mirai_Vfx_Context ctx, uint resource) { return uint2(0u); }
int mirai_vfx_emitter_birth(Mirai_Vfx_Context ctx, uint resource, uint birth, out uint seed) { seed = 0u; return -1; }
uint2 mirai_vfx_particle_id(Mirai_Vfx_Context ctx) { return uint2(0u); }
uint mirai_vfx_state_load(Mirai_Vfx_Context ctx, uint word) { return 0u; }
void mirai_vfx_state_store(Mirai_Vfx_Context ctx, uint word, uint value) {}
uint mirai_vfx_data_count(Mirai_Vfx_Context ctx, uint resource) { return 0u; }
uint mirai_vfx_data_word(Mirai_Vfx_Context ctx, uint resource, uint entry, uint word) { return 0u; }
bool mirai_vfx_data_append(Mirai_Vfx_Context ctx, uint resource, out uint entry) { entry = 0u; return false; }
void mirai_vfx_data_store(Mirai_Vfx_Context ctx, uint resource, uint entry, uint word, uint value) {}
uint mirai_vfx_grid_word_load(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, bool written) { return 0u; }
void mirai_vfx_grid_word_store(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, uint value) {}
uint mirai_vfx_grid_word_add(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, uint value) { return 0u; }
int mirai_vfx_grid_word_min(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, int value) { return 0; }
int mirai_vfx_grid_word_max(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, int value) { return 0; }
float4 mirai_vfx_grid_load_written(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer) { return float4(0.0); }
void mirai_vfx_grid_write(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer, float4 value) {}
Mirai_Vfx_View mirai_vfx_view() { return (Mirai_Vfx_View)0; }
float mirai_vfx_scene_depth(float2 uv) { return 0.0; }
float3 mirai_vfx_scene_normal(float2 uv) { return float3(0.0); }
float mirai_vfx_scene_roughness(float2 uv) { return 1.0; }
#else
float4 mirai_vfx_texture(uint index, float2 uv, float level);
Mirai_Vfx_Surface mirai_vfx_surface_sample(Mirai_Vfx_Context ctx, uint resource, inout uint seed);
Mirai_Vfx_Surface mirai_vfx_surface_at(Mirai_Vfx_Context ctx, uint resource, uint triangle, float2 barycentric);
// The births of a channel resource in this frame, and the index-th of them.
uint mirai_vfx_channel_count(Mirai_Vfx_Context ctx, uint resource);
Mirai_Vfx_Birth mirai_vfx_channel_birth(Mirai_Vfx_Context ctx, uint resource, uint index);
Mirai_Vfx_Bone mirai_vfx_bone_sample(Mirai_Vfx_Context ctx, uint resource, inout uint seed);
Mirai_Vfx_Bone mirai_vfx_bone_at(Mirai_Vfx_Context ctx, uint resource, uint bone, float along);
Mirai_Vfx_Grid mirai_vfx_grid(Mirai_Vfx_Context ctx, uint resource);
float4 mirai_vfx_grid_load(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer);
float4 mirai_vfx_grid_sample(Mirai_Vfx_Context ctx, uint resource, float3 position, uint layer);
float4 mirai_vfx_grid_splatted(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer);
void mirai_vfx_grid_store(Mirai_Vfx_Cell cell, uint layer, float4 value);
void mirai_vfx_grid_splat(Mirai_Vfx_Context ctx, uint resource, float3 position, uint layer, float4 value);
Mirai_Vfx_Neighbors mirai_vfx_neighbors(Mirai_Vfx_Context ctx, float3 position);
bool mirai_vfx_neighbor_next(inout Mirai_Vfx_Neighbors walk, out Mirai_Vfx_Neighbor neighbor);
Mirai_Vfx_Hit mirai_vfx_trace(Mirai_Vfx_Context ctx, float3 origin, float3 direction, float distance);
uint mirai_vfx_emitter_capacity(Mirai_Vfx_Context ctx, uint resource);
uint mirai_vfx_emitter_alive(Mirai_Vfx_Context ctx, uint resource);
uint mirai_vfx_emitter_drawn(Mirai_Vfx_Context ctx, uint resource, uint i);
bool mirai_vfx_emitter_particle(Mirai_Vfx_Context ctx, uint resource, uint slot, out Mirai_Vfx_Particle value);
uint mirai_vfx_emitter_word(Mirai_Vfx_Context ctx, uint resource, uint slot, uint word);
uint2 mirai_vfx_emitter_births(Mirai_Vfx_Context ctx, uint resource);
int mirai_vfx_emitter_birth(Mirai_Vfx_Context ctx, uint resource, uint birth, out uint seed);
uint2 mirai_vfx_particle_id(Mirai_Vfx_Context ctx);
uint mirai_vfx_state_load(Mirai_Vfx_Context ctx, uint word);
void mirai_vfx_state_store(Mirai_Vfx_Context ctx, uint word, uint value);
uint mirai_vfx_data_count(Mirai_Vfx_Context ctx, uint resource);
uint mirai_vfx_data_word(Mirai_Vfx_Context ctx, uint resource, uint entry, uint word);
bool mirai_vfx_data_append(Mirai_Vfx_Context ctx, uint resource, out uint entry);
void mirai_vfx_data_store(Mirai_Vfx_Context ctx, uint resource, uint entry, uint word, uint value);
uint mirai_vfx_grid_word_load(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, bool written);
void mirai_vfx_grid_word_store(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, uint value);
uint mirai_vfx_grid_word_add(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, uint value);
int mirai_vfx_grid_word_min(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, int value);
int mirai_vfx_grid_word_max(Mirai_Vfx_Context ctx, uint resource, int3 index, uint word, int value);
float4 mirai_vfx_grid_load_written(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer);
void mirai_vfx_grid_write(Mirai_Vfx_Context ctx, uint resource, int3 index, uint layer, float4 value);
Mirai_Vfx_View mirai_vfx_view();
float mirai_vfx_scene_depth(float2 uv);
float3 mirai_vfx_scene_normal(float2 uv);
float mirai_vfx_scene_roughness(float2 uv);
#endif
#endif
