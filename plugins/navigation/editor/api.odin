package navigation_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

@(storage)
Navigation_Api :: struct {provider:editor.Api_Provider}

NAVIGATION_API_DEFAULT :: Navigation_Api{provider={register=register}}

Build_Params :: struct {
    min:[3]f32 `mirai:"optional,label=Corner of the box to build again; without min and max: everything"`,
    max:[3]f32 `mirai:"optional"`,
}

Inspect_Params :: struct {
    class:[32]u8 `mirai:"text,optional,label=The class; empty is the first"`,
    min:[3]f32 `mirai:"optional,label=Corner of the box to look in; without min and max: everything"`,
    max:[3]f32 `mirai:"optional"`,
    limit:u32 `mirai:"optional,min=1,max=2048,clamp,label=Polygons and links listed at most"`,
}

Agent_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
}

Move_Params :: struct {
    entity:editor.Api_Entity_Text `mirai:"text,entity"`,
    to:[3]f32 `mirai:"optional,label=Where it walks; omitted with no target: it stops"`,
    target:editor.Api_Entity_Text `mirai:"text,entity,optional,label=An entity it follows instead"`,
    distance:f32 `mirai:"optional,min=0,unit=m,label=Kept from the target"`,
}

Path_Params :: struct {
    class:[32]u8 `mirai:"text,optional,label=The class; empty is the first"`,
    from:[3]f32,
    to:[3]f32,
    up:f32 `mirai:"optional,unit=m,label=How high the agent jumps; omitted or below 0: as its class"`,
    across:f32 `mirai:"optional,unit=m,label=How far it jumps; omitted or below 0: as its class"`,
    down:f32 `mirai:"optional,unit=m,label=How far it drops; omitted or below 0: as its class"`,
    abilities:nav.Nav_Abilities `mirai:"optional,label=What it can do besides walking by name; omitted: every ability"`,
    excluded:nav.Nav_Areas `mirai:"optional,label=The areas it never walks by name"`,
}

Nav_Status_Result :: struct {
    ready:bool,
    classes:[]Nav_Class_Status,
    builds:nav.Build_Stats,
}
Nav_Class_Status :: struct {
    name,space:string,
    radius,height:f32 `mirai:"unit=m"`,
    collision:string,
    voxel,zone_size:f32 `mirai:"optional,unit=m,label=Of a class of the air or the water"`,
    zones,nodes,split_blocks:int `mirai:"optional,label=Of a class of the air or the water"`,
    climb,jump_up,jump_across,drop,tile_width:f32 `mirai:"optional,unit=m,label=Of a class of the surface"`,
    tiles,polygons,links,regions,portals:int `mirai:"optional,label=Of a class of the surface"`,
    connections_refused:u64 `mirai:"optional"`,
    waiting,building,unloaded:int `mirai:"label=Tiles or zones that wait for a build, build, or wait for their collision to load"`,
}

Nav_Build_Result :: struct {
    queued:bool,
}

Nav_Bake_Result :: struct {
    asset:base.Asset_Id,
    path:string,
    tiles:int,
    settled:bool,
}

Nav_Inspect_Result :: struct {
    class:string,
    space:string `mirai:"optional,label=Air for a class of the air or the water"`,
    tiles:[]Nav_Tile_Result,
    polygons:[]Nav_Polygon_Result,
    links:[]Nav_Link_Result,
    zones:[]Nav_Zone_Result `mirai:"optional"`,
    cells:[]Nav_Cell_Result `mirai:"optional,label=Free cells sampled at the voxels of the corners and the center of the box"`,
    more:bool `mirai:"label=More than limit were inside the box"`,
}
Nav_Tile_Result :: struct {
    coord:[2]i32,
    polygons:int,
    min,max:[3]f32,
}
Nav_Polygon_Result :: struct {
    area:string,
    vertices:[][3]f32,
    edges:[]string `mirai:"label=wall, inner or border to the next tile"`,
}
Nav_Link_Result :: struct {
    kind:string,
    start,end:[3]f32,
    two_way,rested:bool,
    up,across,down:f32 `mirai:"unit=m"`,
    abilities:[]string,
    cost:f32,
    generated:bool `mirai:"optional,label=The meshes made it"`,
    made_by:base.Entity_Id `mirai:"optional,label=The entity that made it"`,
}
Nav_Zone_Result :: struct {
    coord:[3]i32,
    nodes,split_blocks:int,
    min,max:[3]f32,
}
Nav_Cell_Result :: struct {
    kind:string `mirai:"label=voxel or node"`,
    min,max:[3]f32,
}

Nav_Corner_Result :: struct {
    position:[3]f32,
    link:string `mirai:"optional,label=The kind of the link it crosses there"`,
    lands:[3]f32 `mirai:"optional,label=Where the link lands"`,
}

Nav_Agent_Result :: struct {
    state:string,
    far:bool,
    note:string `mirai:"optional"`,
    speed:f32 `mirai:"optional,label=Of an agent far"`,
    complete,arrived:bool `mirai:"optional"`,
    class:string `mirai:"optional"`,
    target:base.Entity_Id `mirai:"optional"`,
    goal:[3]f32,
    partial:bool,
    replans:int,
    looking:bool,
    crossing:string `mirai:"optional,label=The kind of the link it crosses"`,
    by_game:bool `mirai:"optional"`,
    from,to:[3]f32 `mirai:"optional"`,
    corners:[]Nav_Corner_Result,
    corridor:int `mirai:"optional"`,
}

Nav_Path_Result :: struct {
    class,status:string,
    partial:bool,
    cost:f32,
    polygons,cells:int `mirai:"optional"`,
    corners:[]Nav_Corner_Result,
}

@(private)
register :: proc(s:^editor.Session) {
    inspect_defaults:=Inspect_Params{limit=256}
    path_defaults:=Path_Params{up=-1,across=-1,down=-1}
    editor.api_method_register(s,{name="nav.status",summary="The navigation meshes of the shown world: for each class of Navigation_Settings its size and what it can jump or drop, its tiles, polygons and links, the tiles that wait for a build, are building, or wait for their collision to load (unloaded: they keep what they have), the sections and portals of its coarse graph, and what the builds did (dropped: tiles that went with their sections or, in a run, with the terrain not loaded; regions: sections of the coarse graph made). Read it after editing collision to know when the meshes caught up.",flags={.Read_Only},result=type_info_of(Nav_Status_Result),run=status})
    editor.api_method_register(s,{name="nav.build",summary="Builds again the tiles of every class inside a box (min and max), or all of them, even where nothing changed. The meshes build by themselves when collision, a Nav_Area or a Nav_Bounds changes: this is for what they cannot see.",params=type_info_of(Build_Params),result=type_info_of(Nav_Build_Result),run=build})
    editor.api_method_register(s,{name="nav.bake",summary="Saves the navigation meshes with the edited scene, or with the section edited in its world: the first time it makes a .navmesh beside the scene and names it in the Navigation_Bake of an entity of the scene, in one undo step. Neither reaches the disk before the scene is saved; until then the editor keeps the .navmesh as the meshes, in memory. A section keeps the tiles over its box, and loads and drops them with it; the scene that holds it keeps the rest with the coarse graph of every section. A world that loads the scene starts with those meshes and builds only the tiles whose collision changed.",result=type_info_of(Nav_Bake_Result),run=bake_call})
    editor.api_method_register(s,{name="nav.inspect",summary="The mesh of a class inside a box, or all of it: its tiles, its polygons (vertices, area and whether each edge is a wall, inner or a border to the next tile) and its links (kind, ends, direction, whether both ends rest on the mesh, what they need to be crossed and who made them). For a class of the air or the water, its zones and the free cells (nodes and voxels of the octree) inside the box.",params=type_info_of(Inspect_Params),defaults=&inspect_defaults,flags={.Read_Only},result=type_info_of(Nav_Inspect_Result),run=inspect})
    editor.api_method_register(s,{name="nav.agent",summary="What a Nav_Agent of the shown world does: its class, state (Idle, Waiting, Moving, Crossing, Arrived, Failed), goal or target, whether its path is partial, the next corners it heads for, the link it crosses and how many times it planned again. An agent far from the players, off where its section is not loaded, says far, with the speed it goes at and, as its corners, what is left of its route through the coarse graph. Use it in Play to see why an agent goes where it goes.",params=type_info_of(Agent_Params),flags={.Read_Only},result=type_info_of(Nav_Agent_Result),run=agent})
    editor.api_method_register(s,{name="nav.move",summary="Asks a Nav_Agent of the running world to walk to a point, to follow an entity at a distance, or to stop (neither to nor target): what a game asks with nav_move_to, nav_follow and nav_stop. For trying agents in Play; nav.agent tells what it does then.",params=type_info_of(Move_Params),result=type_info_of(Nav_Build_Result),run=move})
    editor.api_method_register(s,{name="nav.path",summary="The path an agent of a class would walk, or fly or swim for a class of the air or the water, between two points now: its corners, the links it crosses with their kind, its cost and whether it reaches the end (partial: as near as it can). up, across, down and abilities say what the agent can cross; omitted, what its class can.",params=type_info_of(Path_Params),defaults=&path_defaults,flags={.Read_Only},result=type_info_of(Nav_Path_Result),run=path})
}

@(private)
navigation_of :: proc(s:^editor.Session,call:^api.Call) -> (n:^nav.Navigation,w:core.World_Ref,ok:bool) {
    w=editor.shown_world(s)
    if w.data!=nil {n=core.world_storage_of(w,nav.Navigation)}
    if n==nil {api.call_fail(call,api.INVALID_PARAMS,"The shown world has no navigation: activate the plugin navigation in project.mirai");return}
    return n,w,true
}

@(private)
class_of :: proc(call:^api.Call,n:^nav.Navigation,name:[]u8) -> (class:int,ok:bool) {
    wanted:=base.text_get(name)
    if !n.ready || n.count==0 {api.call_fail(call,api.INVALID_PARAMS,"The navigation meshes are not made yet: the physics of the shown world must be ready and Navigation_Settings must have a class");return}
    if wanted=="" {return 0,true}
    class=nav.class_find(n,wanted)
    if class<0 {api.call_failf(call,api.INVALID_PARAMS,"No class %q in Navigation_Settings: nav.status lists them",wanted);return}
    return class,true
}

@(private)
status :: proc(s:^editor.Session,call:^api.Call) {
    n,_,ok:=navigation_of(s,call)
    if !ok {return}
    classes:=make([]Nav_Class_Status,n.count,call.allocator)
    for i in 0..<n.count {
        class:=&n.classes[i].class
        c:=&n.classes[i]
        tiles,polygons,links,dirty,building,zones,nodes,blocks,unloaded:=0,0,0,0,0,0,0,0,0
        for &tile in c.mesh.tiles {if tile.used {tiles+=1;polygons+=len(tile.data.polys)}}
        for &link in c.mesh.links {if link.used {links+=1}}
        for &zone in c.volume.zones {if zone.used {zones+=1;nodes+=len(zone.data.nodes);blocks+=len(zone.data.voxels)}}
        it:=base.hash_map_iterator(&c.marks)
        for _,mark in base.hash_map_iterate(&it) {
            if mark.dirty && !mark.unloaded {dirty+=1}
            if mark.unloaded {unloaded+=1}
            if mark.building {building+=1}
        }
        shown:=&classes[i]
        shown^={name=base.text_get(class.name[:]),space=fmt.tprintf("%v",class.space),radius=class.radius,height=class.height,waiting=dirty,building=building,unloaded=unloaded}
        shown.collision=phys.collision_name(s.app.info if s.app!=nil else nil,phys.Collision_Preset,i64(class.collision))
        if class.space!=.Surface {
            shown.voxel,shown.zone_size,shown.zones,shown.nodes,shown.split_blocks=c.volume.voxel,c.volume.zone_size,zones,nodes,blocks
            continue
        }
        shown.climb,shown.jump_up,shown.jump_across,shown.drop,shown.tile_width=class.climb,class.jump_up,class.jump_across,class.drop,c.mesh.tile_width
        shown.tiles,shown.polygons,shown.links=tiles,polygons,links
        shown.regions,shown.portals,shown.connections_refused=len(c.coarse.regions),len(c.coarse.portals),u64(c.mesh.failed)
    }
    api.call_result(call,Nav_Status_Result)^={n.ready,classes,n.stats}
}

@(private)
build :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Build_Params)
    w:=editor.shown_world(s)
    requests:^nav.Nav_Build_Requests
    if w.data!=nil {requests=core.world_storage_of(w,nav.Nav_Build_Requests)}
    if requests==nil {api.call_fail(call,api.INVALID_PARAMS,"The shown world has no navigation: activate the plugin navigation in project.mirai");return}
    box:mm.Aabb
    if p.min!={} || p.max!={} {
        box={mm.vec3_min(p.min,p.max),mm.vec3_max(p.min,p.max)}
        if box.min==box.max {box.max+=0.001}
    }
    nav.nav_rebuild(requests,box)
    api.call_result(call,Nav_Build_Result).queued=true
}

@(private)
inspect :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Inspect_Params)
    n,world,ok:=navigation_of(s,call)
    if !ok {return}
    class,found:=class_of(call,n,p.class[:])
    if !found {return}
    whole:=p.min=={} && p.max=={}
    box:=WHOLE_WORLD if whole else mm.Aabb{mm.vec3_min(p.min,p.max),mm.vec3_max(p.min,p.max)}
    if nav.class_in_volume(n,class) {
        if whole {box=volume_bounds(&n.classes[class].volume)}
        inspect_volume(call,n,class,box,int(p.limit))
        return
    }
    mesh:=&n.classes[class].mesh
    limit:=int(p.limit)
    r:=api.call_result(call,Nav_Inspect_Result)
    r.class=base.text_get(n.classes[class].class.name[:])
    tiles:=make([dynamic]Nav_Tile_Result,call.allocator)
    for &tile in mesh.tiles {
        if !tile.used || !overlaps(tile.data.bounds,box) {continue}
        append(&tiles,Nav_Tile_Result{{i32(tile.data.coord.x),i32(tile.data.coord.y)},len(tile.data.polys),tile.data.bounds.min,tile.data.bounds.max})
    }
    polygons:=make([dynamic]Nav_Polygon_Result,call.allocator)
    written:=0
    tiles: for &tile in mesh.tiles {
        if !tile.used || !overlaps(tile.data.bounds,box) {continue}
        for &poly in tile.data.polys {
            corners:[ai.NAV_VERTS_PER_POLY]mm.Vec3
            count:=ai.nav_poly_vertices(&tile,&poly,&corners)
            if !overlaps(mm.aabb_from_points(corners[:count]),box) {continue}
            if written>=limit {r.more=true;break tiles}
            written+=1
            shown:=Nav_Polygon_Result{area=area_name(world,poly.area),vertices=make([][3]f32,count,call.allocator),edges=make([]string,count,call.allocator)}
            for k in 0..<count {
                shown.vertices[k]=corners[k]
                neighbor:=poly.neighbor[k]
                shown.edges[k]=neighbor==ai.NAV_EDGE_WALL?"wall":neighbor&ai.NAV_EDGE_PORTAL!=0?"border":"inner"
            }
            append(&polygons,shown)
        }
    }
    links:=make([dynamic]Nav_Link_Result,call.allocator)
    for &link in mesh.links {
        if !link.used {continue}
        if !overlaps({mm.vec3_min(link.desc.start,link.desc.end),mm.vec3_max(link.desc.start,link.desc.end)},box) {continue}
        if written>=limit {r.more=true;break}
        written+=1
        shown:=Nav_Link_Result{kind=link_kind_name(world,link.desc.kind),two_way=link.desc.two_way,rested=link.start_poly!=0 && link.end_poly!=0}
        shown.start=link.start_point if link.start_poly!=0 else link.desc.start
        shown.end=link.end_point if link.end_poly!=0 else link.desc.end
        shown.up,shown.across,shown.down=link.desc.need.up,link.desc.need.across,link.desc.need.down
        shown.abilities,shown.cost=abilities_names(call,world,link.desc.need.abilities),link.desc.cost
        if link.desc.owner&nav.LINK_OWNER_GENERATED!=0 {shown.generated=true} else {shown.made_by=entity_id(world,core.Entity(link.desc.owner))}
        append(&links,shown)
    }
    r.tiles,r.polygons,r.links=tiles[:],polygons[:],links[:]
}

@(private) WHOLE_WORLD :: mm.Aabb{{-max(f32),-max(f32),-max(f32)},{max(f32),max(f32),max(f32)}}

// The box of the zones of a volume; the free cells are sampled inside it.
@(private)
volume_bounds :: proc(volume:^ai.Nav_Volume) -> mm.Aabb {
    bounds:=mm.AABB_EMPTY
    for &zone in volume.zones {
        if !zone.used {continue}
        box:=ai.nav_volume_zone_box(volume,zone.data.coord)
        bounds.min,bounds.max=mm.vec3_min(bounds.min,box.min),mm.vec3_max(bounds.max,box.max)
    }
    return bounds
}

// The zones of a volume inside a box and their free cells: nodes and voxels.
@(private)
inspect_volume :: proc(call:^api.Call,n:^nav.Navigation,class:int,box:mm.Aabb,limit:int) {
    volume:=&n.classes[class].volume
    r:=api.call_result(call,Nav_Inspect_Result)
    r.class,r.space=base.text_get(n.classes[class].class.name[:]),"Air"
    zones:=make([dynamic]Nav_Zone_Result,call.allocator)
    for &zone in volume.zones {
        if !zone.used || !overlaps(ai.nav_volume_zone_box(volume,zone.data.coord),box) {continue}
        zone_box:=ai.nav_volume_zone_box(volume,zone.data.coord)
        append(&zones,Nav_Zone_Result{zone.data.coord,len(zone.data.nodes),len(zone.data.voxels),zone_box.min,zone_box.max})
    }
    // The free cells inside the box, sampled at the voxels of its corners and center.
    cells_found:=make([dynamic]Nav_Cell_Result,call.allocator)
    size:=box.max-box.min
    step:=max(volume.voxel,max(size.x,size.y,size.z)/16)
    seen:=make(map[ai.Nav_Ref]bool,64,context.temp_allocator)
    cells: for z:=box.min.z;z<=box.max.z;z+=step {
        for y:=box.min.y;y<=box.max.y;y+=step {
            for x:=box.min.x;x<=box.max.x;x+=step {
                ref,free:=ai.nav_volume_find(volume,{x,y,z})
                if !free || ref in seen {continue}
                if len(cells_found)>=limit {r.more=true;break cells}
                seen[ref]=true
                cell_box,_:=ai.nav_volume_ref_box(volume,ref)
                append(&cells_found,Nav_Cell_Result{"voxel" if ai.nav_volume_ref_layer(ref)<0 else "node",cell_box.min,cell_box.max})
            }
        }
    }
    r.zones,r.cells=zones[:],cells_found[:]
}

// The path through a volume between two points, pulled tight.
@(private)
path_volume :: proc(call:^api.Call,n:^nav.Navigation,class:int,from_point,to_point:mm.Vec3) {
    settings:=&n.classes[class].class
    volume:=&n.classes[class].volume
    extents:=mm.Vec3{1,1,1}*max(settings.radius*4,0.5)
    from,start,found_from:=ai.nav_volume_find_nearest(volume,from_point,extents)
    to,end,found_to:=ai.nav_volume_find_nearest(volume,to_point,extents)
    if !found_from || !found_to {
        api.call_failf(call,api.INVALID_PARAMS,"%s is not near the free space of the volume of class %q: nav.inspect shows its zones and cells",!found_from?"from":"to",base.text_get(settings.name[:]))
        return
    }
    q:ai.Nav_Volume_Query
    if !ai.nav_volume_query_init(&q,1<<15,context.temp_allocator) {api.call_fail(call,api.SERVER_ERROR,"No memory for the search");return}
    refs:=make([]ai.Nav_Ref,4096,context.temp_allocator)
    count,status,partial:=ai.nav_volume_find_path(&q,volume,from,to,start,end,refs)
    target:=end
    if partial && count>0 {
        box,_:=ai.nav_volume_ref_box(volume,refs[count-1])
        target=mm.vec3_min(mm.vec3_max(end,box.min),box.max)
    }
    corners:=make([]mm.Vec3,512,context.temp_allocator)
    n_corners,_:=ai.nav_volume_straight_path(volume,start,target,refs[:count],corners)
    shown:=make([]Nav_Corner_Result,n_corners,call.allocator)
    for corner,i in corners[:n_corners] {shown[i].position=corner}
    api.call_result(call,Nav_Path_Result)^={class=base.text_get(settings.name[:]),status=fmt.tprintf("%v",status),partial=partial,cost=ai.search_cost(&q.search) if status==.Found else 0,cells=count,corners=shown}
}

@(private)
path :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Path_Params)
    n,world,ok:=navigation_of(s,call)
    if !ok {return}
    class,found:=class_of(call,n,p.class[:])
    if !found {return}
    if nav.class_in_volume(n,class) {
        path_volume(call,n,class,p.from,p.to)
        return
    }
    settings:=&n.classes[class].class
    mesh:=&n.classes[class].mesh
    can:=ai.Nav_Need{up=p.up if p.up>=0 else settings.jump_up,across=p.across if p.across>=0 else settings.jump_across,down=p.down if p.down>=0 else settings.drop}
    can.abilities=u32(p.abilities) if editor.tool_call_given(call,"abilities") else max(u32)
    filter:=nav.filter_make(&n.settings,p.excluded,can)
    extents:=mm.Vec3{1,2,1}*max(settings.radius*4,0.5)
    from,start,found_from:=ai.nav_find_nearest(mesh,p.from,extents,&filter)
    to,end,found_to:=ai.nav_find_nearest(mesh,p.to,extents,&filter)
    if !found_from || !found_to {
        api.call_failf(call,api.INVALID_PARAMS,"%s is not near the mesh of class %q: nav.inspect shows where it is",!found_from?"from":"to",base.text_get(settings.name[:]))
        return
    }
    q:ai.Nav_Query
    if !ai.nav_query_init(&q,8192,context.temp_allocator) {api.call_fail(call,api.SERVER_ERROR,"No memory for the search");return}
    refs:=make([]ai.Nav_Ref,4096,context.temp_allocator)
    count,status,partial:=ai.nav_find_path(&q,mesh,from,to,start,end,&filter,refs)
    corners:=make([]ai.Nav_Corner,512,context.temp_allocator)
    target:=end
    if partial && count>0 {target,_=ai.nav_closest_point_on_poly(mesh,refs[count-1],end)}
    count=ai.nav_path_straighten(mesh,&filter,start,target,refs,count)
    n_corners,_:=ai.nav_straight_path(mesh,start,target,refs[:count],corners)
    shown:=make([]Nav_Corner_Result,n_corners,call.allocator)
    for corner,i in corners[:n_corners] {
        shown[i].position=corner.position
        if .Link not_in corner.flags {continue}
        if link:=ai.nav_link_of(mesh,corner.ref);link!=nil {
            shown[i].link=link_kind_name(world,link.desc.kind)
            _,shown[i].lands,_,_=ai.nav_link_ends(link,corner.ref)
        }
    }
    api.call_result(call,Nav_Path_Result)^={class=base.text_get(settings.name[:]),status=fmt.tprintf("%v",status),partial=partial,cost=ai.search_cost(&q.search) if status==.Found else 0,polygons=count,corners=shown}
}

@(private)
overlaps :: proc "contextless" (a,b:mm.Aabb) -> bool {
    return a.min.x<=b.max.x && a.max.x>=b.min.x && a.min.y<=b.max.y && a.max.y>=b.min.y && a.min.z<=b.max.z && a.max.z>=b.min.z
}

// The abilities of a mask by name.
@(private)
abilities_names :: proc(call:^api.Call,world:core.World_Ref,abilities:u32) -> []string {
    names:=make([dynamic]string,call.allocator)
    for entry in core.names_of(world.info,nav.Nav_Ability) {
        if entry.value>=0 && entry.value<32 && abilities&(1<<uint(entry.value))!=0 {append(&names,entry.name)}
    }
    return names[:]
}

@(private)
area_name :: proc(w:core.World_Ref,area:u8) -> string {
    if name,found:=core.name_of(w.info,nav.Nav_Area_Kind,i64(area));found {return name}
    return fmt.tprintf("%d",area)
}
@(private)
link_kind_name :: proc(w:core.World_Ref,kind:u8) -> string {
    if name,found:=core.name_of(w.info,nav.Nav_Link_Kind,i64(kind));found {return name}
    return fmt.tprintf("%d",kind)
}
@(private)
entity_id :: proc(w:core.World_Ref,e:core.Entity) -> base.Entity_Id {
    ids:=core.world_table_of(w,core.Id)
    if ids==nil {return 0}
    id,found:=core.get(ids,e)
    return id.value if found else 0
}

@(private)
agent :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Agent_Params)
    n,world,ok:=navigation_of(s,call)
    if !ok {return}
    e,named:=editor.api_call_entity(call,world,p.entity[:],game=s.mode!=.Edit)
    if !named {return}
    paths:=core.world_table_of(world,nav.Nav_Path)
    agents:=core.world_table_of(world,nav.Nav_Agent)
    far:=far_of(world,e)
    if agents==nil || !core.has(agents,e) && far==nil {api.call_failf(call,api.INVALID_PARAMS,"%s is not an entity with a Nav_Agent in the shown world",base.text_get(p.entity[:]));return}
    r:=api.call_result(call,Nav_Agent_Result)
    value:nav.Nav_Path
    has:=false
    // A far agent is off: its rows are read whether on or not.
    if paths!=nil {
        if found:=cast(^nav.Nav_Path)core.raw_find(core.raw(paths),type_info_of(nav.Nav_Path),e);found!=nil {value,has=found^,true}
    }
    if !has {
        r.state,r.note="Idle","no path yet: Nav_Path is added on the first tick of a run"
        return
    }
    r.state,r.far=fmt.tprintf("%v",value.state),far!=nil
    if far!=nil {r.speed,r.complete,r.arrived=far.speed,far.complete,far.arrived}
    known:=value.class>=0 && int(value.class)<n.count
    if known {r.class=base.text_get(n.classes[value.class].class.name[:])}
    if value.target!=core.NONE {r.target=entity_id(world,value.target)}
    r.goal,r.partial,r.replans,r.looking=value.goal,value.partial,int(value.replans),value.looking
    if value.state==.Crossing {r.crossing,r.by_game,r.from,r.to=link_kind_name(world,u8(value.kind)),value.manual,value.from,value.to}
    corners:=make([dynamic]Nav_Corner_Result,call.allocator)
    corridor:=value.corridor
    switch {
    case far!=nil:
        // What is left of its route: count 0 makes it again at its next step.
        for corner in far.route[clamp(far.next,0,far.count):clamp(far.count,0,nav.NAV_FAR_POINTS)] {append(&corners,Nav_Corner_Result{position=corner})}
    case known && nav.class_in_volume(n,int(value.class)):
        points:[16]mm.Vec3
        count,_:=ai.nav_volume_straight_path(&n.classes[value.class].volume,corridor.position,corridor.target,corridor.path[:clamp(corridor.count,0,ai.NAV_CORRIDOR_CAPACITY)],points[:])
        for corner in points[:count] {append(&corners,Nav_Corner_Result{position=corner})}
        r.corridor=int(max(corridor.count,0))
    case known:
        mesh:=&n.classes[value.class].mesh
        points:[16]ai.Nav_Corner
        count,_:=ai.nav_straight_path(mesh,corridor.position,corridor.target,corridor.path[:clamp(corridor.count,0,ai.NAV_CORRIDOR_CAPACITY)],points[:])
        for corner in points[:count] {
            shown:=Nav_Corner_Result{position=corner.position}
            if .Link in corner.flags {
                if link:=ai.nav_link_of(mesh,corner.ref);link!=nil {shown.link=link_kind_name(world,link.desc.kind)}
            }
            append(&corners,shown)
        }
        r.corridor=int(max(corridor.count,0))
    }
    r.corners=corners[:]
}

// The Nav_Far of an agent far from the players, whose rows are off; nil when it is not far.
@(private)
far_of :: proc(w:core.World_Ref,e:core.Entity) -> ^nav.Nav_Far {
    fars:=core.world_table_of(w,nav.Nav_Far)
    if fars==nil || e==core.NONE {return nil}
    return cast(^nav.Nav_Far)core.raw_find(core.raw(fars),type_info_of(nav.Nav_Far),e)
}

@(private)
move :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Move_Params)
    if !editor.playing(s) {editor.api_no_game(call,"nav.move works on the running world");return}
    world:=editor.shown_world(s)
    requests:=core.world_storage_of(world,nav.Nav_Requests)
    agents:=core.world_table_of(world,nav.Nav_Agent)
    e,named:=editor.api_call_entity(call,world,p.entity[:],game=true)
    if !named {return}
    if requests==nil || agents==nil || !core.has(agents,e) && far_of(world,e)==nil {api.call_failf(call,api.INVALID_PARAMS,"%s is not an entity with a Nav_Agent in the running world",base.text_get(p.entity[:]));return}
    switch {
    case p.target[0]!=0:
        target,known:=editor.api_call_entity(call,world,p.target[:],"target",true)
        if !known {return}
        nav.nav_follow(requests,e,target,p.distance)
    case p.to!={}:
        nav.nav_move_to(requests,e,p.to)
    case:
        nav.nav_stop(requests,e)
    }
    api.call_result(call,Nav_Build_Result).queued=true
}
