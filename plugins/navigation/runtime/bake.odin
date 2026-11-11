package navigation

import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// The .navmesh of a scene: the tiles of every class, with the hash of what
// each was built from, the links the build generated, the zones of the
// classes of the air and the water, and the coarse graph. A world that loads
// the scene starts with them; the build checks every tile and makes again
// only those whose input changed. The scene of a section saves the tiles and
// zones over its box, and the scene that holds it those outside the boxes of
// its sections with the whole coarse graph: what a section saves comes with
// it when it loads and goes when it is dropped. The editor writes it as the
// meshes of the edited scene change (nav.bake makes it the first time), and
// saving the scene saves it.

BAKE_KIND :: asset.Fourcc(u32('N')|u32('A')<<8|u32('V')<<16|u32('M')<<24)
BAKE_EXTENSION :: ".navmesh"
BAKE_VERSION :: 3

// The navigation meshes the scene saves, on an entity of the scene; none:
// built when it loads. Each one in the world, of the scene or of a section,
// puts in the meshes what they do not have when it comes.
@(component,description="Names the .navmesh the scene saves its navigation meshes in: a world that loads the scene starts with them and builds only the tiles whose collision changed. nav.bake writes it.")
Navigation_Bake :: struct {
    asset:base.Asset_Id `mirai:"owned,readonly,kind=.navmesh"`,
}

Bake_Class :: struct {
    name:[32]u8 `mirai:"text"`,
    space:Nav_Space,
    config:ai.Nav_Build_Config,
    volume_config:ai.Nav_Volume_Config,
    collision_layers,collision_block:u32, // of the filter it was made with (Class_Mesh.filter); both 0: the defaults
    tile_first,tile_count:u32,
    link_first,link_count:u32,
    zone_first,zone_count:u32,
    region_first,region_count:u32,
    portal_first,portal_count:u32,
    way_first,way_count:u32,
    corner_first,corner_count:u32,
}

// What a .navmesh holds: the tiles and zones that touch `inside` when
// `within`, but those that `outside` covers (the sections that save their
// own), and the coarse graph when `coarse`.
Bake_Filter :: struct {
    within:bool,
    inside:mm.Aabb,
    outside:[]mm.Aabb,
    coarse:bool,
}
BAKE_ALL :: Bake_Filter{coarse=true}

@(private)
bake_takes :: proc(filter:Bake_Filter,box:mm.Aabb) -> bool {
    if filter.within && !mm.aabb_overlaps(filter.inside,box) {return false}
    if len(filter.outside)==0 {return true}
    s:Nav_Sections
    for b in filter.outside[:min(len(filter.outside),NAV_SECTIONS_MAX)] {
        s.items[s.count]={box=b,away=true}
        s.count+=1
        s.away[s.away_count]=b
        s.away_count+=1
    }
    return !sections_covered(&s,box)
}

Bake_Zone :: struct {
    coord:[3]i32,
    hash:u64,
    first:[ai.NAV_VOLUME_MAX_LAYERS+1]u32,
    node_first,node_count:u32,
    voxel_first,voxel_count:u32,
}

Bake_Tile :: struct {
    coord:[2]i32,
    hash:u64,
    bounds:mm.Aabb,
    cell_size,cell_height:f32,
    vertex_first,vertex_count:u32,
    poly_first,poly_count:u32,
    detail_vertex_first,detail_vertex_count:u32,
    detail_triangle_first,detail_triangle_count:u32,
    bv_first,bv_count:u32,
}

Bake_Link :: struct {
    start,end:[3]f32,
    radius:f32,
    kind:u8,
    two_way:bool,
    area:u8,
    cost:f32,
    need:ai.Nav_Need,
    owner:u64,
}

// The meshes as a .navmesh with that id, what the filter takes of them.
bake_bytes :: proc(n:^Navigation,id:base.Asset_Id,types:^asset.Types,filter:=BAKE_ALL,allocator:=context.allocator) -> (data:[]u8,error:asset.Error) {
    classes:=make([dynamic]Bake_Class,context.temp_allocator)
    tiles:=make([dynamic]Bake_Tile,context.temp_allocator)
    links:=make([dynamic]Bake_Link,context.temp_allocator)
    vertices:=make([dynamic][3]f32,context.temp_allocator)
    polys:=make([dynamic]ai.Nav_Poly,context.temp_allocator)
    details:=make([dynamic]ai.Nav_Detail,context.temp_allocator)
    detail_vertices:=make([dynamic][3]f32,context.temp_allocator)
    triangles:=make([dynamic]ai.Nav_Detail_Triangle,context.temp_allocator)
    bv:=make([dynamic]ai.Nav_Bv,context.temp_allocator)
    zones:=make([dynamic]Bake_Zone,context.temp_allocator)
    nodes:=make([dynamic]ai.Nav_Volume_Node,context.temp_allocator)
    voxels:=make([dynamic]u64,context.temp_allocator)
    regions:=make([dynamic]ai.Nav_Coarse_Region,context.temp_allocator)
    portals:=make([dynamic]ai.Nav_Portal,context.temp_allocator)
    ways:=make([dynamic]ai.Nav_Coarse_Edge,context.temp_allocator)
    corners:=make([dynamic][3]f32,context.temp_allocator)
    for i in 0..<n.count {
        c:=&n.classes[i]
        class:=Bake_Class{
            name=c.class.name,space=c.class.space,config=c.config,volume_config=c.volume_config,collision_layers=u32(c.filter.filter.layers),collision_block=u32(c.filter.filter.block),tile_first=u32(len(tiles)),link_first=u32(len(links)),zone_first=u32(len(zones)),
            region_first=u32(len(regions)),portal_first=u32(len(portals)),way_first=u32(len(ways)),corner_first=u32(len(corners)),
        }
        if filter.coarse {
            append(&regions,..c.coarse.regions[:]);append(&portals,..c.coarse.portals[:]);append(&ways,..c.coarse.edges[:])
            for corner in c.coarse.corners {append(&corners,corner)}
        }
        class.region_count,class.portal_count=u32(len(regions))-class.region_first,u32(len(portals))-class.portal_first
        class.way_count,class.corner_count=u32(len(ways))-class.way_first,u32(len(corners))-class.corner_first
        taken:=make(map[u64]bool,context.temp_allocator)
        for &zone in c.volume.zones {
            if !zone.used || !bake_takes(filter,ai.nav_volume_zone_box(&c.volume,zone.data.coord)) {continue}
            d:=&zone.data
            append(&zones,Bake_Zone{coord=d.coord,hash=d.hash,first=d.first,node_first=u32(len(nodes)),node_count=u32(len(d.nodes)),voxel_first=u32(len(voxels)),voxel_count=u32(len(d.voxels))})
            append(&nodes,..d.nodes)
            append(&voxels,..d.voxels)
        }
        class.zone_count=u32(len(zones))-class.zone_first
        for &tile in c.mesh.tiles {
            if !tile.used || !bake_takes(filter,tile.data.bounds) {continue}
            d:=&tile.data
            taken[generated_owner(d.coord)]=true
            append(&tiles,Bake_Tile{
                coord=d.coord,hash=d.hash,bounds=d.bounds,cell_size=d.cell_size,cell_height=d.cell_height,
                vertex_first=u32(len(vertices)),vertex_count=u32(len(d.vertices)),
                poly_first=u32(len(polys)),poly_count=u32(len(d.polys)),
                detail_vertex_first=u32(len(detail_vertices)),detail_vertex_count=u32(len(d.detail_vertices)),
                detail_triangle_first=u32(len(triangles)),detail_triangle_count=u32(len(d.detail_triangles)),
                bv_first=u32(len(bv)),bv_count=u32(len(d.bv)),
            })
            for v in d.vertices {append(&vertices,v)}
            append(&polys,..d.polys)
            if len(d.details)==len(d.polys) {append(&details,..d.details)} else {for _ in d.polys {append(&details,ai.Nav_Detail{})}}
            for v in d.detail_vertices {append(&detail_vertices,v)}
            append(&triangles,..d.detail_triangles)
            append(&bv,..d.bv)
        }
        for &link in c.mesh.links {
            if !link.used || link.desc.owner&LINK_OWNER_GENERATED==0 || !taken[link.desc.owner] {continue}
            l:=link.desc
            append(&links,Bake_Link{start=l.start,end=l.end,radius=l.radius,kind=l.kind,two_way=l.two_way,area=l.area,cost=l.cost,need=l.need,owner=l.owner})
        }
        class.tile_count=u32(len(tiles))-class.tile_first
        class.link_count=u32(len(links))-class.link_first
        append(&classes,class)
    }
    document:asset.Document
    asset.document_init(&document,BAKE_KIND,id,allocator)
    defer asset.document_destroy(&document)
    document.kind_version=BAKE_VERSION
    asset.document_put(&document,types,"classes",classes[:]) or_return
    asset.document_put(&document,types,"tiles",tiles[:]) or_return
    asset.document_put(&document,types,"links",links[:]) or_return
    asset.document_put(&document,types,"vertices",vertices[:],{.Bulk},.LZ) or_return
    asset.document_put(&document,types,"polys",polys[:],{.Bulk},.LZ) or_return
    asset.document_put(&document,types,"details",details[:],{.Bulk},.LZ) or_return
    asset.document_put(&document,types,"detail_vertices",detail_vertices[:],{.Bulk},.LZ) or_return
    asset.document_put(&document,types,"detail_triangles",triangles[:],{.Bulk},.LZ) or_return
    asset.document_put(&document,types,"bv",bv[:],{.Bulk},.LZ) or_return
    asset.document_put(&document,types,"zones",zones[:]) or_return
    asset.document_put(&document,types,"nodes",nodes[:],{.Bulk},.LZ) or_return
    asset.document_put(&document,types,"voxels",voxels[:],{.Bulk},.LZ) or_return
    asset.document_put(&document,types,"regions",regions[:]) or_return
    asset.document_put(&document,types,"portals",portals[:]) or_return
    asset.document_put(&document,types,"ways",ways[:]) or_return
    asset.document_put(&document,types,"corners",corners[:],{.Bulk},.LZ) or_return
    return asset.document_bytes(&document,allocator)
}

// Tile or zone keys by class of the meshes, with any value.
Bake_Keys :: ^[NAV_CLASS_CAPACITY]base.Hash_Map(u64)

@(private)
bake_rows :: proc(file:^asset.Asset,types:^asset.Types,name:string,$T:typeid) -> (rows:[]T,ok:bool) {
    found,error:=asset.asset_rows(file,types,name,"",T)
    if error==.Not_Found {return nil,true}
    return found,error==.None
}

// Puts in the meshes of n, for the classes whose name and build are the same,
// what an open .navmesh has and they do not: the tiles and zones, with the
// hash each was built from, the links generated from those tiles, and the
// regions of the coarse graph. With only, just the tiles and zones whose key
// it holds for their class of n, and no coarse graph. How many tiles and
// zones; false when the file is not one this version reads, leaving the
// meshes as they were.
bake_read :: proc(n:^Navigation,file:^asset.Asset,types:^asset.Types,only:Bake_Keys=nil) -> (count:int,ok:bool) {
    if asset.kind_check(file,BAKE_KIND,BAKE_VERSION)!=.None {return}
    classes:=bake_rows(file,types,"classes",Bake_Class) or_return
    tiles:=bake_rows(file,types,"tiles",Bake_Tile) or_return
    links:=bake_rows(file,types,"links",Bake_Link) or_return
    vertices:=bake_rows(file,types,"vertices",[3]f32) or_return
    polys:=bake_rows(file,types,"polys",ai.Nav_Poly) or_return
    details:=bake_rows(file,types,"details",ai.Nav_Detail) or_return
    detail_vertices:=bake_rows(file,types,"detail_vertices",[3]f32) or_return
    triangles:=bake_rows(file,types,"detail_triangles",ai.Nav_Detail_Triangle) or_return
    bv:=bake_rows(file,types,"bv",ai.Nav_Bv) or_return
    zones:=bake_rows(file,types,"zones",Bake_Zone) or_return
    nodes:=bake_rows(file,types,"nodes",ai.Nav_Volume_Node) or_return
    voxels:=bake_rows(file,types,"voxels",u64) or_return
    regions:=bake_rows(file,types,"regions",ai.Nav_Coarse_Region) or_return
    portals:=bake_rows(file,types,"portals",ai.Nav_Portal) or_return
    ways:=bake_rows(file,types,"ways",ai.Nav_Coarse_Edge) or_return
    corners:=bake_rows(file,types,"corners",[3]f32) or_return
    within :: proc "contextless" (first,count:u32,length:int) -> bool {return u64(first)+u64(count)<=u64(length)}
    for class in classes {
        if !within(class.tile_first,class.tile_count,len(tiles)) || !within(class.link_first,class.link_count,len(links)) || !within(class.zone_first,class.zone_count,len(zones)) {return}
        if !within(class.region_first,class.region_count,len(regions)) || !within(class.portal_first,class.portal_count,len(portals)) || !within(class.way_first,class.way_count,len(ways)) || !within(class.corner_first,class.corner_count,len(corners)) {return}
    }
    for zone in zones {
        if !within(zone.node_first,zone.node_count,len(nodes)) || !within(zone.voxel_first,zone.voxel_count,len(voxels)) {return}
    }
    for tile in tiles {
        if !within(tile.vertex_first,tile.vertex_count,len(vertices)) || !within(tile.poly_first,tile.poly_count,len(polys)) || !within(tile.poly_first,tile.poly_count,len(details)) ||
            !within(tile.detail_vertex_first,tile.detail_vertex_count,len(detail_vertices)) || !within(tile.detail_triangle_first,tile.detail_triangle_count,len(triangles)) || !within(tile.bv_first,tile.bv_count,len(bv)) {return}
    }
    for &class in classes {
        at:=class_find(n,base.text_get(class.name[:]))
        if at<0 || n.classes[at].class.space!=class.space {continue}
        c:=&n.classes[at]
        if !bake_filter_same(class,c.filter) {continue}
        if only!=nil && only[at].count==0 {continue}
        if class.space!=.Surface {
            if c.volume_config!=class.volume_config {continue}
            for zone in zones[class.zone_first:][:class.zone_count] {
                if ai.nav_volume_zone_at(&c.volume,zone.coord)!=nil || only!=nil && !base.hash_map_contains(&only[at],zone_key(zone.coord)) {continue}
                data,made:=ai.nav_volume_data_alloc(int(zone.node_count),int(zone.voxel_count))
                if !made {continue}
                data.coord,data.hash,data.first,data.layers=zone.coord,zone.hash,zone.first,u8(c.volume_config.layers)
                copy(data.nodes,nodes[zone.node_first:][:zone.node_count])
                copy(data.voxels,voxels[zone.voxel_first:][:zone.voxel_count])
                if !ai.nav_volume_add_zone(&c.volume,data) {ai.nav_volume_data_free(&data);continue}
                if mark,_:=base.hash_map_insert(&c.marks,zone_key(zone.coord));mark!=nil {mark.hash=zone.hash}
                count+=1
            }
            continue
        }
        if c.config!=class.config {continue}
        added:=make(map[u64]bool,context.temp_allocator)
        for tile in tiles[class.tile_first:][:class.tile_count] {
            if ai.nav_mesh_tile_at(&c.mesh,tile.coord)!=nil || only!=nil && !base.hash_map_contains(&only[at],coord_key(tile.coord)) {continue}
            data,made:=ai.nav_tile_data_alloc(int(tile.vertex_count),int(tile.poly_count),int(tile.detail_vertex_count),int(tile.detail_triangle_count),int(tile.bv_count))
            if !made {continue}
            data.coord,data.hash,data.bounds,data.cell_size,data.cell_height=tile.coord,tile.hash,tile.bounds,tile.cell_size,tile.cell_height
            for v,k in vertices[tile.vertex_first:][:tile.vertex_count] {data.vertices[k]=v}
            copy(data.polys,polys[tile.poly_first:][:tile.poly_count])
            copy(data.details,details[tile.poly_first:][:tile.poly_count])
            for v,k in detail_vertices[tile.detail_vertex_first:][:tile.detail_vertex_count] {data.detail_vertices[k]=v}
            copy(data.detail_triangles,triangles[tile.detail_triangle_first:][:tile.detail_triangle_count])
            copy(data.bv,bv[tile.bv_first:][:tile.bv_count])
            if !ai.nav_mesh_add_tile(&c.mesh,data) {ai.nav_tile_data_free(&data);continue}
            if mark,_:=base.hash_map_insert(&c.marks,coord_key(tile.coord));mark!=nil {mark.hash=tile.hash}
            added[generated_owner(tile.coord)]=true
            count+=1
        }
        for link in links[class.link_first:][:class.link_count] {
            owner:=link.owner|LINK_OWNER_GENERATED
            if !added[owner] {continue}
            ai.nav_mesh_add_link(&c.mesh,{start=link.start,end=link.end,radius=link.radius,kind=link.kind,two_way=link.two_way,area=link.area,cost=link.cost,need=link.need,owner=owner})
        }
        if only==nil && class.region_count>0 {
            graph:ai.Nav_Coarse
            graph.regions=make([dynamic]ai.Nav_Coarse_Region,context.temp_allocator)
            graph.portals=make([dynamic]ai.Nav_Portal,context.temp_allocator)
            graph.edges=make([dynamic]ai.Nav_Coarse_Edge,context.temp_allocator)
            graph.corners=make([dynamic]mm.Vec3,context.temp_allocator)
            append(&graph.regions,..regions[class.region_first:][:class.region_count])
            append(&graph.portals,..portals[class.portal_first:][:class.portal_count])
            append(&graph.edges,..ways[class.way_first:][:class.way_count])
            for corner in corners[class.corner_first:][:class.corner_count] {append(&graph.corners,corner)}
            ai.nav_coarse_merge(&c.coarse,&graph)
        }
    }
    n.revision+=1
    return count,true
}

// Puts in the meshes what the .navmesh of a Navigation_Bake has and they do
// not; with only, just the tiles and zones of those keys.
@(private)
bake_load :: proc(n:^Navigation,bake:Navigation_Bake,app:^host.App,problems:^core.Problems,only:Bake_Keys=nil) {
    if bake.asset=={} || app.assets==nil {return}
    started:=time.tick_now()
    file:asset.Asset
    if host.assets_file(app.assets,bake.asset,BAKE_KIND,&file)!=.None {
        core.report(problems,core.NONE,"navigation.bake","The .navmesh of the scene (Navigation_Bake) cannot be read: the meshes are built from the collision; bake it again with nav.bake")
        return
    }
    defer asset.asset_close(&file)
    count,ok:=bake_read(n,&file,&app.assets.types,only)
    // Read once a section or the scene that has it comes: a load counts it.
    host.load_asset_done(&app.load_profile,bake.asset,.Plugin,host.assets_file_bytes(app.assets,bake.asset),time.duration_nanoseconds(time.tick_since(started)),0,!ok,phase=.Nav_Bake)
    host.load_phase_add(app,.Nav_Bake,0,count)
    if !ok {
        core.report(problems,core.NONE,"navigation.bake","The .navmesh of the scene is of another version or damaged: the meshes are built from the collision; bake it again with nav.bake")
    }
}

// Whether a class of a bake was made of the collision a class is made of now.
// A bake that does not say was made of the defaults.
@(private)
bake_filter_same :: proc "contextless" (class:Bake_Class,filter:phys.Query_Filter) -> bool {
    layers,block:=class.collision_layers,class.collision_block
    if layers==0 && block==0 {
        defaults:=phys.QUERY_FILTER_DEFAULT.filter
        layers,block=u32(defaults.layers),u32(defaults.block)
    }
    return u32(filter.filter.layers)==layers && u32(filter.filter.block)==block
}
