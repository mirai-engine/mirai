// The heights of the scene around the camera (render.heights_pass): the top
// of what a ray of the view can meet over each place of the ground, from maps
// of depth drawn straight down from over the scene, the nearest the finest.
// Nothing is over them, so a ray is not sent while it stays over them: it is
// sent from where it first comes down to them, or not at all. They only say
// where nothing is; what a ray meets, the ray finds.
#ifndef MIRAI_HEIGHTS_SLANG
#define MIRAI_HEIGHTS_SLANG

// The entry of the texture table with the heights: HEIGHT_MAPS squares of
// HEIGHTS_SIDE texels side by side, the height of the top over each texel and
// its neighbours, and under them, in blocks of HEIGHTS_BLOCK texels a side,
// the highest of each block.
#define HEIGHTS_TEXTURE 4u
#define HEIGHT_MAPS 2u
#define HEIGHTS_SIDE 512
#define HEIGHTS_BLOCK 16
// Blocks a ray crosses in a map before it goes on in the next.
#define HEIGHTS_BLOCKS 48
// Of a texel, how far over the top held a ray counts as over it: the detail
// rays meet is not always the one the maps were drawn at.
static const float HEIGHTS_OVER = 0.25;

// render.Gpu_Heights: count maps, each x and z of its middle and half its
// side, metres; the bottom and the top of everything.
struct Heights {
    uint count;
    float bottom;
    float top;
    float pad0;
    float4 maps[HEIGHT_MAPS];
};

float heights_load(int2 texel) {
    return material_textures[HEIGHTS_TEXTURE].Load(int3(texel, 0)).r;
}

// How far along a cell a point of it leaves it going at `speed`, in the
// units of the cell: low its corner, side its side.
float heights_leave(float2 at, float2 speed, float2 low, float side) {
    float2 to = select(speed > 0.0, low + side - at, low - at);
    float2 t = select(speed != 0.0, to / select(speed != 0.0, speed, float2(1.0)), float2(FLT_MAX));
    return max(min(t.x, t.y), 0.0);
}

// How far a ray goes from its origin, up to reach, surely over everything the
// maps hold: reach when it meets nothing of them, else where a ray has to be
// sent from. 0 without maps or from a place they do not hold.
float heights_clear(Heights h, float3 origin, float3 direction, float reach) {
    float t = 0.0;
    for (uint map = 0u; map < h.count; map++) {
        float4 place = h.maps[map];
        float cell = 2.0 * place.z / float(HEIGHTS_SIDE);
        // Texels from the corner of the map, row 0 at its far +Z side.
        float2 from = float2(origin.x - place.x + place.z, place.y + place.z - origin.z) / cell;
        float2 speed = float2(direction.x, -direction.z) / cell;
        float over = HEIGHTS_OVER * cell;
        // Into the next cell, a thousandth of a texel.
        float nudge = 1e-3 / max(max(abs(speed.x), abs(speed.y)), 1e-6);
        int2 corner = int2(int(map) * HEIGHTS_SIDE, 0);
        for (int i = 0; i < HEIGHTS_BLOCKS; i++) {
            if (t >= reach) return reach;
            float y = origin.y + direction.y * t;
            if ((y < h.bottom && direction.y <= 0.0) || (y > h.top && direction.y >= 0.0)) return reach;
            float2 at = from + speed * t;
            if (any(at < 0.0) || any(at >= float(HEIGHTS_SIDE))) break;
            int2 block = int2(at) / HEIGHTS_BLOCK;
            float left = min(t + heights_leave(at, speed, float2(block * HEIGHTS_BLOCK), float(HEIGHTS_BLOCK)), reach);
            float low = min(y, origin.y + direction.y * left);
            if (low > heights_load(int2(corner.x / HEIGHTS_BLOCK + block.x, HEIGHTS_SIDE + block.y)) + over) {
                t = left + nudge;
                continue;
            }
            for (int k = 0; k < 2 * HEIGHTS_BLOCK && t < left; k++) {
                at = from + speed * t;
                int2 texel = clamp(int2(floor(at)), block * HEIGHTS_BLOCK, block * HEIGHTS_BLOCK + HEIGHTS_BLOCK - 1);
                float next = min(t + heights_leave(at, speed, float2(texel), 1.0), left);
                low = min(origin.y + direction.y * t, origin.y + direction.y * next);
                if (!(low > heights_load(corner + texel) + over)) return t;
                t = next + nudge;
            }
            if (t < left) return t;
        }
    }
    return min(t, reach);
}

#endif
