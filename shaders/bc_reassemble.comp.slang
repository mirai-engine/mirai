#include "native.slang"
#include "shared_constants.slang"

#define MIRAI_GROUP_X 32
#define MIRAI_GROUP_Y 1
#define MIRAI_GROUP_Z 1

[[vk::binding(SLOT_PASS0, 0)]] ByteAddressBuffer planes :
    register(MIRAI_REGISTER(t, SLOT_PASS0), space0);
[[vk::binding(SLOT_PASS1, 0)]] RWByteAddressBuffer blocks :
    register(MIRAI_REGISTER(u, SLOT_PASS1), space0);

static const uint modeStride = 4u * (4u + 2u * BC_FIELD_PLANES + BC_FIELD_SPANS);

groupshared uint seen[BC_FIELD_MODES];
groupshared uint members[BC_FIELD_MODES];

uint read_bits(uint address, uint bit, uint count) {
    uint byteOffset = address + bit / 8u;
    uint shift = (byteOffset & 3u) * 8u + (bit & 7u);
    uint aligned = byteOffset & ~3u;
    uint value = planes.Load(aligned) >> shift;
    if (shift + count > 32u)
        value |= planes.Load(aligned + 4u) << (32u - shift);
    return value & (0xffffffffu >> (32u - count));
}

void reassemble(uint block, uint words, uint mode, uint rank) {
    uint descriptor = 16u + mode * modeStride;
    uint bitPlanes = planes.Load(descriptor + 4u);
    uint widths = descriptor + 8u;
    uint spans = widths + 4u * BC_FIELD_PLANES;
    uint offsets = spans + 4u * BC_FIELD_SPANS;
    uint4 value = uint4(planes.Load(descriptor), 0, 0, 0);
    uint bitGroups = planes.Load(offsets + 4u * BC_FIELD_PLANES);
    uint bitRank = rank + planes.Load(offsets + 4u * (BC_FIELD_PLANES + 1u));
    for (uint i = 0; i < BC_FIELD_SPANS; ++i) {
        uint span = planes.Load(spans + i * 4u);
        if (span == 0u) break;
        uint wire = span & 255u;
        uint field = (span >> 8u) & 255u;
        uint source = (span >> 16u) & 255u;
        uint count = span >> 24u;
        uint address = planes.Load(offsets + field * 4u);
        uint bits = 0u;
        if (((bitPlanes >> field) & 1u) != 0u) {
            address += source * bitGroups + bitRank / 8u;
            for (uint j = 0u; j < count; ++j) {
                bits |= read_bits(address + j * bitGroups, bitRank & 7u, 1u) << j;
            }
        } else {
            address += rank * planes.Load(widths + field * 4u);
            bits = read_bits(address, source, count);
        }
        uint lane = wire / 32u;
        uint shift = wire & 31u;
        value[lane] |= bits << shift;
        if (shift + count > 32u) value[lane + 1u] |= bits >> (32u - shift);
    }
    uint at = block * words * 4u;
    if (words == 2u) blocks.Store2(at, value.xy);
    else blocks.Store4(at, value);
}

[shader("compute")]
[numthreads(MIRAI_GROUP_X, MIRAI_GROUP_Y, MIRAI_GROUP_Z)]
void main(uint3 group : SV_GroupID, uint3 local : SV_GroupThreadID,
          uint3 id : SV_DispatchThreadID) {
    uint4 header = planes.Load4(0);
    uint columns = header.x;
    uint rows = header.y;
    uint words = header.z;
    uint modes = header.w;
    if (modes == 0u) {
        if (id.x < columns * rows) reassemble(id.x, words, 0u, id.x);
        return;
    }
    uint lane = local.x;
    uint row = group.x;
    uint modeStart = 16u + modes * modeStride;
    uint rowStart = (modeStart + columns * rows + 3u) & ~3u;
    if (lane < modes) seen[lane] = planes.Load(rowStart + (row * BC_FIELD_MODES + lane) * 4u);
    for (uint base = 0; base < columns; base += MIRAI_GROUP_X) {
        if (lane < modes) members[lane] = 0u;
        GroupMemoryBarrierWithGroupSync();
        uint bit = 1u << lane;
        uint column = base + lane;
        uint index = row * columns + column;
        uint mode = 0u;
        if (column < columns) {
            mode = read_bits(modeStart + index, 0u, 8u);
            InterlockedOr(members[mode], bit);
        }
        GroupMemoryBarrierWithGroupSync();
        if (column < columns) {
            uint rank = seen[mode] + countbits(members[mode] & (bit - 1u));
            reassemble(index, words, mode, rank);
        }
        GroupMemoryBarrierWithGroupSync();
        if (lane < modes) seen[lane] += countbits(members[lane]);
    }
}
