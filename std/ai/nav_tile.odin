package ai

import "base:runtime"
import math "mirai:std/math"

// One tile of a navigation mesh, as a build leaves it: convex polygons of up
// to NAV_VERTS_PER_POLY vertices over the walkable surface of a square of the
// tile grid, with a detail mesh that gives the height of the surface inside
// each polygon. Every slice lives in `block`, one allocation: a tile is freed,
// copied or saved as one piece. Y is up; the grid of tiles lies on XZ.

NAV_VERTS_PER_POLY :: 6

// Areas: what the surface of a polygon is. 0 is not walkable and never
// reaches a tile; the rest are ids that a project names, up to NAV_AREA_MAX.
NAV_AREA_BLOCKED :: u8(0)
NAV_AREA_WALKABLE :: u8(1)
NAV_AREA_MAX :: u8(63)

// What lies across each edge of a polygon (Nav_Poly.neighbor):
//   0                      a wall: nothing walkable
//   1..NAV_EDGE_PORTAL-1   the polygon of the same tile with index value-1
//   NAV_EDGE_PORTAL|side   the border of the tile on that side, which joins the next tile
NAV_EDGE_WALL :: u16(0)
NAV_EDGE_PORTAL :: u16(0x8000)
// Sides of a tile, for portals: the neighbor tile is at coord + NAV_SIDE_OFFSET[side].
Nav_Side :: enum u8 {Pos_X,Pos_Z,Neg_X,Neg_Z}
NAV_SIDE_OFFSET :: [Nav_Side][2]i32{.Pos_X={1,0},.Pos_Z={0,1},.Neg_X={-1,0},.Neg_Z={0,-1}}

Nav_Poly :: struct {
    vertices:[NAV_VERTS_PER_POLY]u16, // into Nav_Tile_Data.vertices, counter-clockwise seen from above (+Y)
    neighbor:[NAV_VERTS_PER_POLY]u16, // across the edge from vertices[i] to vertices[(i+1)%count]
    count:u8,
    area:u8,
}

// The detail triangles of a polygon. Indices of a triangle below the vertex
// count of the polygon name its vertices; the rest name
// detail_vertices[vertex_first+index-count].
Nav_Detail :: struct {
    vertex_first,triangle_first:u32,
    vertex_count,triangle_count:u16,
}
// a, b, c and in the fourth byte, per edge (bits 0-1: a-b, 2-3: b-c, 4-5: c-a), 1 when the edge lies on the boundary of the polygon.
Nav_Detail_Triangle :: [4]u8

// A node of the bounding volume tree over the polygons of a tile, in depth
// first order. Bounds are in cells from the minimum of the tile bounds
// (cell_size across, cell_height up). A leaf names its polygon; an inner node
// gives as -index how many nodes to skip to leave its subtree.
Nav_Bv :: struct {
    min,max:[3]u16,
    index:i32,
}

Nav_Tile_Data :: struct {
    coord:[2]i32,
    bounds:math.Aabb,            // of the polygons and their detail
    cell_size,cell_height:f32,   // of the build, for the bounds of the tree
    vertices:[]math.Vec3,
    polys:[]Nav_Poly,
    details:[]Nav_Detail,        // one per polygon
    detail_vertices:[]math.Vec3,
    detail_triangles:[]Nav_Detail_Triangle,
    bv:[]Nav_Bv,
    poly_links:[]u32,            // one per polygon, zero: the mesh keeps here the first connection of each polygon once the tile is added
    hash:u64,                    // what the tile was built from; the builder leaves it to the caller
    block:[]byte,                // owns every slice above
    allocator:runtime.Allocator,
}

nav_tile_data_free :: proc(data:^Nav_Tile_Data) {
    if data.allocator.procedure!=nil {delete(data.block,data.allocator)}
    data^={}
}

// How a tile is built, in world units. The agent fields describe the class
// of agent the mesh is for.
Nav_Build_Config :: struct {
    origin:math.Vec3,         // corner of tile (0,0) on XZ; its y is ignored
    tile_size:i32,            // cells across a tile, along x and z
    cell_size:f32,            // m across a cell (x and z)
    cell_height:f32,          // m along y of a cell
    agent_radius:f32,         // m: walls are kept this far
    agent_height:f32,         // m of clearance above the surface
    agent_climb:f32,          // m of a step the agent walks up or down
    agent_max_slope:f32,      // radians: steeper triangles are not walkable
    min_region_area:i32,      // cells: smaller islands are dropped
    merge_region_area:i32,    // cells: smaller regions are merged into their neighbors
    max_edge_length:f32,      // m of a border edge before it is split; 0: no limit
    max_edge_error:f32,       // m a simplified border may stray from the voxels
    detail_sample_distance:f32, // m between height samples of the detail mesh; 0: no samples
    detail_max_error:f32,     // m the detail mesh may stray from the samples
}

NAV_AREA_POINTS :: 64

// A volume that marks the area of the surface inside it: a polygon on XZ (up
// to NAV_AREA_POINTS points, either way round, convex or not) between two
// heights. Later volumes win where they overlap; NAV_AREA_BLOCKED removes the
// surface.
Nav_Area_Volume :: struct {
    points:[NAV_AREA_POINTS][2]f32,

    count:u8,
    area:u8,
    min_y,max_y:f32,
}

// Triangles in world space, wound either way: everything that touches the tile
// and the border around it that its agent radius needs.
Nav_Build_Input :: struct {
    vertices:[]math.Vec3,
    indices:[]u32,
    triangle_areas:[]u8,      // per triangle, or none: walkable ones are NAV_AREA_WALKABLE
    volumes:[]Nav_Area_Volume,
}

Nav_Build_Status :: enum u8 {
    Built,
    Empty,         // nothing walkable in the tile: no data
    Invalid,       // a value of the config or the input is out of range
    Out_Of_Memory,
    Too_Large,     // more vertices or polygons than a tile holds (u16 indices)
}
