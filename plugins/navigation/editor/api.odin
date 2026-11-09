package navigation_editor

import "core:fmt"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/ai"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"
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
    entity:base.Entity_Id,
}

Move_Params :: struct {
    entity:base.Entity_Id,
    to:[3]f32 `mirai:"optional,label=Where it walks; omitted with no target: it stops"`,
    target:base.Entity_Id `mirai:"optional,label=An entity it follows instead"`,
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

@(private)
register :: proc(s:^editor.Session) {
    inspect_defaults:=Inspect_Params{limit=256}
    path_defaults:=Path_Params{up=-1,across=-1,down=-1}
    editor.api_method_register(s,{name="nav.status",summary="The navigation meshes of the shown world: for each class of Navigation_Settings its size and what it can jump or drop, its tiles, polygons and links, the tiles that wait for a build, are building, or wait for their collision to load (unloaded: they keep what they have), the sections and portals of its coarse graph, and what the builds did (dropped: tiles that went with their sections or, in a run, with the terrain not loaded; regions: sections of the coarse graph made). Read it after editing collision to know when the meshes caught up.",flags={.Read_Only},result_schema=STATUS_SCHEMA,run=status})
    editor.api_method_register(s,{name="nav.build",summary="Builds again the tiles of every class inside a box (min and max), or all of them, even where nothing changed. The meshes build by themselves when collision, a Nav_Area or a Nav_Bounds changes: this is for what they cannot see.",params=Build_Params,params_info=type_info_of(Build_Params),result_schema=`{"type":"object","properties":{"queued":{"type":"boolean"}},"required":["queued"]}`,run=build})
    editor.api_method_register(s,{name="nav.bake",summary="Saves the navigation meshes with the edited scene, or with the section edited in its world: the first time it makes a .navmesh beside the scene and names it in the Navigation_Bake of an entity of the scene, in one undo step. Neither reaches the disk before the scene is saved; until then the editor keeps the .navmesh as the meshes, in memory. A section keeps the tiles over its box, and loads and drops them with it; the scene that holds it keeps the rest with the coarse graph of every section. A world that loads the scene starts with those meshes and builds only the tiles whose collision changed.",result_schema=BAKE_SCHEMA,run=bake_call})
    editor.api_method_register(s,{name="nav.inspect",summary="The mesh of a class inside a box, or all of it: its tiles, its polygons (vertices, area and whether each edge is a wall, inner or a border to the next tile) and its links (kind, ends, direction, whether both ends rest on the mesh, what they need to be crossed and who made them). For a class of the air or the water, its zones and the free cells (nodes and voxels of the octree) inside the box.",params=Inspect_Params,params_info=type_info_of(Inspect_Params),defaults=&inspect_defaults,flags={.Read_Only},result_schema=INSPECT_SCHEMA,run=inspect})
    editor.api_method_register(s,{name="nav.agent",summary="What a Nav_Agent of the shown world does: its class, state (Idle, Waiting, Moving, Crossing, Arrived, Failed), goal or target, whether its path is partial, the next corners it heads for, the link it crosses and how many times it planned again. An agent far from the players, off where its section is not loaded, says far, with the speed it goes at and, as its corners, what is left of its route through the coarse graph. Use it in Play to see why an agent goes where it goes.",params=Agent_Params,params_info=type_info_of(Agent_Params),flags={.Read_Only},result_schema=AGENT_SCHEMA,run=agent})
    editor.api_method_register(s,{name="nav.move",summary="Asks a Nav_Agent of the running world to walk to a point, to follow an entity at a distance, or to stop (neither to nor target): what a game asks with nav_move_to, nav_follow and nav_stop. For trying agents in Play; nav.agent tells what it does then.",params=Move_Params,params_info=type_info_of(Move_Params),result_schema=`{"type":"object","properties":{"queued":{"type":"boolean"}},"required":["queued"]}`,run=move})
    editor.api_method_register(s,{name="nav.path",summary="The path an agent of a class would walk, or fly or swim for a class of the air or the water, between two points now: its corners, the links it crosses with their kind, its cost and whether it reaches the end (partial: as near as it can). up, across, down and abilities say what the agent can cross; omitted, what its class can.",params=Path_Params,params_info=type_info_of(Path_Params),defaults=&path_defaults,flags={.Read_Only},result_schema=PATH_SCHEMA,run=path})
}

@(private) STATUS_SCHEMA :: `{"type":"object","properties":{"ready":{"type":"boolean"},"classes":{"type":"array"},"builds":{"type":"object"}},"required":["ready","classes"]}`
@(private) INSPECT_SCHEMA :: `{"type":"object","properties":{"class":{"type":"string"},"tiles":{"type":"array"},"polygons":{"type":"array"},"links":{"type":"array"},"zones":{"type":"array"},"cells":{"type":"array"},"more":{"type":"boolean"}},"required":["class","tiles","polygons","links","more"]}`
@(private) AGENT_SCHEMA :: `{"type":"object","properties":{"class":{"type":"string"},"state":{"type":"string"},"goal":{"type":"array"},"corners":{"type":"array"},"partial":{"type":"boolean"},"replans":{"type":"integer"},"far":{"type":"boolean"}},"required":["state","corners","far"]}`
@(private) PATH_SCHEMA :: `{"type":"object","properties":{"class":{"type":"string"},"status":{"type":"string"},"partial":{"type":"boolean"},"cost":{"type":"number"},"corners":{"type":"array"},"polygons":{"type":"integer"},"cells":{"type":"integer"}},"required":["class","status","partial","corners"]}`

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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_bool(w,"ready",n.ready,true)
    api.write_key(w,"classes")
    serial.text_write_raw(w,"[")
    for i in 0..<n.count {
        if i>0 {serial.text_write_raw(w,",")}
        class:=n.classes[i].class
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
        serial.text_write_raw(w,"{")
        api.write_text(w,"name",base.text_get(class.name[:]),true)
        api.write_text(w,"space",fmt.tprintf("%v",class.space))
        api.write_key(w,"radius");api.write_number(w,class.radius)
        api.write_key(w,"height");api.write_number(w,class.height)
        api.write_text(w,"collision",phys.collision_name(s.app.info if s.app!=nil else nil,phys.Collision_Preset,i64(class.collision)))
        if class.space!=.Surface {
            api.write_key(w,"voxel");api.write_number(w,c.volume.voxel)
            api.write_key(w,"zone_size");api.write_number(w,c.volume.zone_size)
            api.write_int(w,"zones",i64(zones))
            api.write_int(w,"nodes",i64(nodes))
            api.write_int(w,"split_blocks",i64(blocks))
            api.write_int(w,"waiting",i64(dirty))
            api.write_int(w,"building",i64(building))
            api.write_int(w,"unloaded",i64(unloaded))
            serial.text_write_raw(w,"}")
            continue
        }
        api.write_key(w,"climb");api.write_number(w,class.climb)
        api.write_key(w,"jump_up");api.write_number(w,class.jump_up)
        api.write_key(w,"jump_across");api.write_number(w,class.jump_across)
        api.write_key(w,"drop");api.write_number(w,class.drop)
        api.write_key(w,"tile_width");api.write_number(w,c.mesh.tile_width)
        api.write_int(w,"tiles",i64(tiles))
        api.write_int(w,"polygons",i64(polygons))
        api.write_int(w,"links",i64(links))
        api.write_int(w,"waiting",i64(dirty))
        api.write_int(w,"building",i64(building))
        api.write_int(w,"unloaded",i64(unloaded))
        api.write_int(w,"regions",i64(len(c.coarse.regions)))
        api.write_int(w,"portals",i64(len(c.coarse.portals)))
        api.write_uint(w,"connections_refused",c.mesh.failed)
        serial.text_write_raw(w,"}")
    }
    serial.text_write_raw(w,"]")
    api.write_key(w,"builds")
    st:=n.stats
    serial.text_write_raw(w,"{")
    api.write_uint(w,"built",st.built,true)
    api.write_uint(w,"emptied",st.emptied)
    api.write_uint(w,"unchanged",st.unchanged)
    api.write_uint(w,"discarded",st.discarded)
    api.write_uint(w,"failed",st.failed)
    api.write_uint(w,"overflowed",st.overflowed)
    api.write_uint(w,"dropped",st.dropped)
    api.write_uint(w,"regions",st.regions)
    serial.text_write_raw(w,"}}")
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
    serial.text_write_raw(call.out,`{"queued":true}`)
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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_text(w,"class",base.text_get(n.classes[class].class.name[:]),true)
    api.write_key(w,"tiles")
    serial.text_write_raw(w,"[")
    first:=true
    for &tile in mesh.tiles {
        if !tile.used || !overlaps(tile.data.bounds,box) {continue}
        if !first {serial.text_write_raw(w,",")}
        first=false
        serial.text_write_raw(w,"{")
        api.write_key(w,"coord",true)
        serial.text_write_raw(w,fmt.tprintf("[%d,%d]",tile.data.coord.x,tile.data.coord.y))
        api.write_int(w,"polygons",i64(len(tile.data.polys)))
        api.write_numbers(w,"min",tile.data.bounds.min)
        api.write_numbers(w,"max",tile.data.bounds.max)
        serial.text_write_raw(w,"}")
    }
    serial.text_write_raw(w,"]")
    api.write_key(w,"polygons")
    serial.text_write_raw(w,"[")
    written:=0
    more:=false
    first=true
    tiles: for &tile in mesh.tiles {
        if !tile.used || !overlaps(tile.data.bounds,box) {continue}
        for &poly in tile.data.polys {
            corners:[ai.NAV_VERTS_PER_POLY]mm.Vec3
            count:=ai.nav_poly_vertices(&tile,&poly,&corners)
            if !overlaps(mm.aabb_from_points(corners[:count]),box) {continue}
            if written>=limit {more=true;break tiles}
            written+=1
            if !first {serial.text_write_raw(w,",")}
            first=false
            serial.text_write_raw(w,"{")
            api.write_text(w,"area",area_name(world,poly.area),true)
            api.write_key(w,"vertices")
            serial.text_write_raw(w,"[")
            for k in 0..<count {
                if k>0 {serial.text_write_raw(w,",")}
                api.write_list(w,corners[k][:])
            }
            serial.text_write_raw(w,"]")
            api.write_key(w,"edges")
            serial.text_write_raw(w,"[")
            for k in 0..<count {
                if k>0 {serial.text_write_raw(w,",")}
                neighbor:=poly.neighbor[k]
                serial.text_write_string(w,neighbor==ai.NAV_EDGE_WALL?"wall":neighbor&ai.NAV_EDGE_PORTAL!=0?"border":"inner")
            }
            serial.text_write_raw(w,"]}")
        }
    }
    serial.text_write_raw(w,"]")
    api.write_key(w,"links")
    serial.text_write_raw(w,"[")
    first=true
    for &link in mesh.links {
        if !link.used {continue}
        if !overlaps({mm.vec3_min(link.desc.start,link.desc.end),mm.vec3_max(link.desc.start,link.desc.end)},box) {continue}
        if written>=limit {more=true;break}
        written+=1
        if !first {serial.text_write_raw(w,",")}
        first=false
        serial.text_write_raw(w,"{")
        api.write_text(w,"kind",link_kind_name(world,link.desc.kind),true)
        api.write_numbers(w,"start",link.start_point if link.start_poly!=0 else link.desc.start)
        api.write_numbers(w,"end",link.end_point if link.end_poly!=0 else link.desc.end)
        api.write_bool(w,"two_way",link.desc.two_way)
        api.write_bool(w,"rested",link.start_poly!=0 && link.end_poly!=0)
        api.write_key(w,"up");api.write_number(w,link.desc.need.up)
        api.write_key(w,"across");api.write_number(w,link.desc.need.across)
        api.write_key(w,"down");api.write_number(w,link.desc.need.down)
        abilities_write(w,world,link.desc.need.abilities)
        api.write_key(w,"cost");api.write_number(w,link.desc.cost)
        if link.desc.owner&nav.LINK_OWNER_GENERATED!=0 {
            api.write_text(w,"made_by","generated")
        } else {
            api.write_key(w,"made_by")
            api.write_id(w,entity_id(world,core.Entity(link.desc.owner)))
        }
        serial.text_write_raw(w,"}")
    }
    serial.text_write_raw(w,"]")
    api.write_bool(w,"more",more)
    serial.text_write_raw(w,"}")
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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_text(w,"class",base.text_get(n.classes[class].class.name[:]),true)
    serial.text_write_raw(w,`,"space":"Air","tiles":[],"polygons":[],"links":[]`)
    api.write_key(w,"zones")
    serial.text_write_raw(w,"[")
    first:=true
    for &zone in volume.zones {
        if !zone.used || !overlaps(ai.nav_volume_zone_box(volume,zone.data.coord),box) {continue}
        if !first {serial.text_write_raw(w,",")}
        first=false
        zone_box:=ai.nav_volume_zone_box(volume,zone.data.coord)
        serial.text_write_raw(w,"{")
        api.write_key(w,"coord",true)
        serial.text_write_raw(w,fmt.tprintf("[%d,%d,%d]",zone.data.coord.x,zone.data.coord.y,zone.data.coord.z))
        api.write_int(w,"nodes",i64(len(zone.data.nodes)))
        api.write_int(w,"split_blocks",i64(len(zone.data.voxels)))
        api.write_numbers(w,"min",zone_box.min)
        api.write_numbers(w,"max",zone_box.max)
        serial.text_write_raw(w,"}")
    }
    serial.text_write_raw(w,"]")
    // The free cells inside the box, sampled at the voxels of its corners and center.
    api.write_key(w,"cells")
    serial.text_write_raw(w,"[")
    written:=0
    more:=false
    size:=box.max-box.min
    step:=max(volume.voxel,max(size.x,size.y,size.z)/16)
    seen:=make(map[ai.Nav_Ref]bool,64,context.temp_allocator)
    cells: for z:=box.min.z;z<=box.max.z;z+=step {
        for y:=box.min.y;y<=box.max.y;y+=step {
            for x:=box.min.x;x<=box.max.x;x+=step {
                ref,free:=ai.nav_volume_find(volume,{x,y,z})
                if !free || ref in seen {continue}
                if written>=limit {more=true;break cells}
                seen[ref]=true
                cell_box,_:=ai.nav_volume_ref_box(volume,ref)
                if written>0 {serial.text_write_raw(w,",")}
                written+=1
                serial.text_write_raw(w,"{")
                layer:=ai.nav_volume_ref_layer(ref)
                api.write_text(w,"kind","voxel" if layer<0 else "node",true)
                api.write_numbers(w,"min",cell_box.min)
                api.write_numbers(w,"max",cell_box.max)
                serial.text_write_raw(w,"}")
            }
        }
    }
    serial.text_write_raw(w,"]")
    api.write_bool(w,"more",more)
    serial.text_write_raw(w,"}")
}

// The path through a volume between two points, pulled tight.
@(private)
path_volume :: proc(call:^api.Call,n:^nav.Navigation,class:int,from_point,to_point:mm.Vec3) {
    settings:=n.classes[class].class
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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_text(w,"class",base.text_get(settings.name[:]),true)
    api.write_text(w,"status",fmt.tprintf("%v",status))
    api.write_bool(w,"partial",partial)
    api.write_key(w,"cost");api.write_number(w,ai.search_cost(&q.search) if status==.Found else 0)
    api.write_int(w,"cells",i64(count))
    api.write_key(w,"corners")
    serial.text_write_raw(w,"[")
    for corner,i in corners[:n_corners] {
        if i>0 {serial.text_write_raw(w,",")}
        serial.text_write_raw(w,"{")
        api.write_numbers(w,"position",corner,true)
        serial.text_write_raw(w,"}")
    }
    serial.text_write_raw(w,"]}")
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
    settings:=n.classes[class].class
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
    w:=call.out
    serial.text_write_raw(w,"{")
    api.write_text(w,"class",base.text_get(settings.name[:]),true)
    api.write_text(w,"status",fmt.tprintf("%v",status))
    api.write_bool(w,"partial",partial)
    api.write_key(w,"cost");api.write_number(w,ai.search_cost(&q.search) if status==.Found else 0)
    api.write_int(w,"polygons",i64(count))
    api.write_key(w,"corners")
    serial.text_write_raw(w,"[")
    for corner,i in corners[:n_corners] {
        if i>0 {serial.text_write_raw(w,",")}
        serial.text_write_raw(w,"{")
        api.write_numbers(w,"position",corner.position,true)
        if .Link in corner.flags {
            if link:=ai.nav_link_of(mesh,corner.ref);link!=nil {
                api.write_text(w,"link",link_kind_name(world,link.desc.kind))
                _,leave,_,_:=ai.nav_link_ends(link,corner.ref)
                api.write_numbers(w,"lands",leave)
            }
        }
        serial.text_write_raw(w,"}")
    }
    serial.text_write_raw(w,"]}")
}

@(private)
overlaps :: proc "contextless" (a,b:mm.Aabb) -> bool {
    return a.min.x<=b.max.x && a.max.x>=b.min.x && a.min.y<=b.max.y && a.max.y>=b.min.y && a.min.z<=b.max.z && a.max.z>=b.min.z
}

// The abilities of a mask by name.
@(private)
abilities_write :: proc(w:^serial.Writer,world:core.World_Ref,abilities:u32) {
    api.write_key(w,"abilities");serial.text_write_raw(w,"[")
    first:=true
    for entry in core.names_of(world.info,nav.Nav_Ability) {
        if entry.value<0 || entry.value>=32 || abilities&(1<<uint(entry.value))==0 {continue}
        if !first {serial.text_write_raw(w,",")}
        first=false
        serial.text_write_string(w,entry.name)
    }
    serial.text_write_raw(w,"]")
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
    id,found:=core.get(core.read(ids),e)
    return id.value if found else 0
}

@(private)
agent :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Agent_Params)
    n,world,ok:=navigation_of(s,call)
    if !ok {return}
    e:=core.entity_of(core.world_entities(world),p.entity)
    paths:=core.world_table_of(world,nav.Nav_Path)
    agents:=core.world_table_of(world,nav.Nav_Agent)
    far:=far_of(world,e)
    if e==core.NONE || agents==nil || !core.has(core.read(agents),e) && far==nil {api.call_failf(call,api.INVALID_PARAMS,"%x is not an entity with a Nav_Agent in the shown world",p.entity);return}
    w:=call.out
    serial.text_write_raw(w,"{")
    value:nav.Nav_Path
    has:=false
    // A far agent is off: its rows are read whether on or not.
    if paths!=nil {
        if found:=cast(^nav.Nav_Path)core.raw_find(core.raw(paths),type_info_of(nav.Nav_Path),e);found!=nil {value,has=found^,true}
    }
    if !has {
        api.write_text(w,"state","Idle",true)
        serial.text_write_raw(w,`,"far":false,"corners":[],"note":"no path yet: Nav_Path is added on the first tick of a run"}`)
        return
    }
    api.write_text(w,"state",fmt.tprintf("%v",value.state),true)
    api.write_bool(w,"far",far!=nil)
    if far!=nil {
        api.write_key(w,"speed")
        api.write_number(w,far.speed)
        api.write_bool(w,"complete",far.complete)
        api.write_bool(w,"arrived",far.arrived)
    }
    class_name:=""
    if value.class>=0 && int(value.class)<n.count {class_name=base.text_get(n.classes[value.class].class.name[:])}
    api.write_text(w,"class",class_name)
    if value.target!=core.NONE {
        api.write_key(w,"target")
        api.write_id(w,entity_id(world,value.target))
    }
    api.write_numbers(w,"goal",value.goal)
    api.write_bool(w,"partial",value.partial)
    api.write_uint(w,"replans",u64(value.replans))
    api.write_bool(w,"looking",value.looking)
    if value.state==.Crossing {
        api.write_text(w,"crossing",link_kind_name(world,u8(value.kind)))
        api.write_bool(w,"by_game",value.manual)
        api.write_numbers(w,"from",value.from)
        api.write_numbers(w,"to",value.to)
    }
    api.write_key(w,"corners")
    serial.text_write_raw(w,"[")
    if far!=nil {
        // What is left of its route: count 0 makes it again at its next step.
        left:=far.route[clamp(far.next,0,far.count):clamp(far.count,0,nav.NAV_FAR_POINTS)]
        for corner,i in left {
            if i>0 {serial.text_write_raw(w,",")}
            serial.text_write_raw(w,"{")
            api.write_numbers(w,"position",corner,true)
            serial.text_write_raw(w,"}")
        }
        serial.text_write_raw(w,"]")
    } else if value.class>=0 && int(value.class)<n.count && nav.class_in_volume(n,int(value.class)) {
        volume:=&n.classes[value.class].volume
        corridor:=value.corridor
        corners:[16]mm.Vec3
        count,_:=ai.nav_volume_straight_path(volume,corridor.position,corridor.target,corridor.path[:clamp(corridor.count,0,ai.NAV_CORRIDOR_CAPACITY)],corners[:])
        for corner,i in corners[:count] {
            if i>0 {serial.text_write_raw(w,",")}
            serial.text_write_raw(w,"{")
            api.write_numbers(w,"position",corner,true)
            serial.text_write_raw(w,"}")
        }
        serial.text_write_raw(w,"]")
        api.write_uint(w,"corridor",u64(max(corridor.count,0)))
    } else if value.class>=0 && int(value.class)<n.count {
        mesh:=&n.classes[value.class].mesh
        corners:[16]ai.Nav_Corner
        corridor:=value.corridor
        count,_:=ai.nav_straight_path(mesh,corridor.position,corridor.target,corridor.path[:clamp(corridor.count,0,ai.NAV_CORRIDOR_CAPACITY)],corners[:])
        for corner,i in corners[:count] {
            if i>0 {serial.text_write_raw(w,",")}
            serial.text_write_raw(w,"{")
            api.write_numbers(w,"position",corner.position,true)
            if .Link in corner.flags {
                if link:=ai.nav_link_of(mesh,corner.ref);link!=nil {api.write_text(w,"link",link_kind_name(world,link.desc.kind))}
            }
            serial.text_write_raw(w,"}")
        }
        serial.text_write_raw(w,"]")
        api.write_uint(w,"corridor",u64(max(corridor.count,0)))
    } else {serial.text_write_raw(w,"]")}
    serial.text_write_raw(w,"}")
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
    if !editor.playing(s) {api.call_fail(call,api.INVALID_PARAMS,"nav.move works on the running world: play.start first");return}
    world:=editor.shown_world(s)
    requests:=core.world_storage_of(world,nav.Nav_Requests)
    agents:=core.world_table_of(world,nav.Nav_Agent)
    e:=core.entity_of(core.world_entities(world),p.entity)
    if requests==nil || agents==nil || e==core.NONE || !core.has(core.read(agents),e) && far_of(world,e)==nil {api.call_failf(call,api.INVALID_PARAMS,"%x is not an entity with a Nav_Agent in the running world",p.entity);return}
    switch {
    case p.target!=0:
        target:=core.entity_of(core.world_entities(world),p.target)
        if target==core.NONE {api.call_failf(call,api.INVALID_PARAMS,"target %x is not an entity of the running world",p.target);return}
        nav.nav_follow(requests,e,target,p.distance)
    case p.to!={}:
        nav.nav_move_to(requests,e,p.to)
    case:
        nav.nav_stop(requests,e)
    }
    serial.text_write_raw(call.out,`{"queued":true}`)
}
