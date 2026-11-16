int2 probe_tile_interior(int2 local, int tile) {
    int last = tile - 1;
    bool x = local.x == 0 || local.x == last;
    bool y = local.y == 0 || local.y == last;
    if (x && y) return int2(local.x == 0 ? last - 1 : 1, local.y == 0 ? last - 1 : 1);
    if (y) return int2(last - local.x, local.y == 0 ? 1 : last - 1);
    if (x) return int2(local.x == 0 ? 1 : last - 1, last - local.y);
    return local;
}
