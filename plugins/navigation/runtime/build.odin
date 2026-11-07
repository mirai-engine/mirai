package navigation

import "core:mem"
import "core:math/linalg"
import "core:time"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/ai"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"
import phys "plugins:physics/runtime"

// Builds the tiles of every class where their input changed: the static
// collision (from the change log of the physics), the Nav_Area boxes and the
// bounds. The input of a tile is gathered here, hashed, and built by a job
// when it differs from what the tile was built from; the job's tile is
// published in a later tick if nothing marked the tile again meanwhile. The
// zones of the classes of the air go the same way, from the collision and
// the bounds of the air. Where only sections that are away are, the tiles and
// zones go; each Navigation_Bake that comes with a section puts back those of
// its .navmesh, and those still missing build. In a run, those that read only
// where the terrain is not loaded go too, and come back from the bakes of the
// world when it loads. The coarse graph of a section here is made again once
// its tiles, or its zones for a class of a volume, settle with other hashes
// than it was made from.

NAV_CHECKS_PER_TICK :: 64      // tiles gathered and hashed in a tick, built or not
NAV_CHANGES_PER_READ :: 256
NAV_TRIANGLES_MAX :: 1<<20     // of the input of one tile
NAV_COARSE_EXPANDED :: 256     // nodes the searches of the ways of a region of the coarse graph expand in a tick

// What the application keeps to build the meshes of a world: the jobs and
// what the build tracks of the world. None of it is the state of the world.
@(storage,host,by_world,free="builds_free")
Navigation_Builds :: struct {
    builds:[dynamic]^Build,
    uid:u64,          // of the Navigation the builds and the tracking below are for
    next_uid:u64,
    cursor:phys.Static_Cursor,
    areas:core.Entity_Map(Area_Seen), // each Nav_Area as it was at the last look
    links:core.Entity_Map(Link_Seen), // each Nav_Link as it was put in the meshes
    obstacles:core.Entity_Map(Area_Seen), // each Nav_Obstacle as it was at the last look
    bounds:[dynamic]mm.Aabb,         // of the Nav_Bounds at the last look; empty: the static collision
    air:[dynamic]mm.Aabb,            // of the Nav_Bounds of the air at the last look
    water:[dynamic]mm.Aabb,          // of the water of the Fluid_Volume rows at the last look, a plane within the bounds
    dry:[dynamic]mm.Aabb,            // of their dry boxes
    boxes:[NAV_CHANGES_PER_READ]mm.Aabb,
    sections:Nav_Sections,           // of this tick
    away:[NAV_SECTIONS_MAX]mm.Aabb,  // the boxes away at the last look
    away_count:int,
    sections_seen:u64,               // the hash of the sections at the last look
    bakes:core.Entity_Map(base.Asset_Id), // each Navigation_Bake put in the meshes, with the asset it named
    bakes_seen:u64,
    coarse_revision,coarse_sections:u64, // what the coarse graph was last checked against
    query:ai.Nav_Query,                  // that finds the ways of the coarse graph
    volume_query:ai.Nav_Volume_Query,    // through the volumes
    region:ai.Nav_Coarse_Build,          // the region of the coarse graph on its way
    region_busy:bool,
    region_class:int,
    region_sections:u64,                 // the hash of the sections it began with
    // The versions each look last saw: a tick that changed none of them skips it.
    bounds_stamps:[7]u64,
    areas_stamps,obstacles_stamps,links_stamps:[6]u64,
    settling:int,         // obstacles that are not blocking yet
    unloaded_seen:u64,    // Unloaded.revision the marks waiting for it were last looked at with
    // By class, the tiles and zones that went in a run where the terrain is not loaded, with the
    // hash of the one each had (0: none), to read again from the bakes.
    paged:[NAV_CLASS_CAPACITY]base.Hash_Map(u64),
    paged_seen:u64,       // Nav_Unloaded.revision and whether the world ran when they were last looked at
    seen:[dynamic]bool,   // scratch of the looks: the entries still there
}

// The versions of a table of boxes in the frame of their entities and of the poses that place them.
@(private)
poses_stamps :: proc "contextless" (rows:core.Read($T),transforms:core.Read(core.Transform),parents:core.Read(core.Parent)) -> [6]u64 {
    return {core.version(rows),core.layout(rows),core.version(transforms),core.layout(transforms),core.version(parents),core.layout(parents)}
}

@(private)
seen_reset :: proc(b:^Navigation_Builds,count:int) -> []bool {
    resize(&b.seen,count)
    for &s in b.seen {s=false}
    return b.seen[:]
}

// Where tiles and zones are made: the bounds of the surface, those of the air,
// and the water with the dry boxes taken out of it.
@(private)
Limits :: struct {surface,air,water,dry:[]mm.Aabb}

// The boxes the zones of a class of a volume fill.
@(private)
limits_of :: proc "contextless" (c:^Class_Mesh,limits:Limits) -> []mm.Aabb {return limits.water if c.class.space==.Water else limits.air}

@(private)
Area_Seen :: struct {
    box:mm.Aabb,
    volume:ai.Nav_Area_Volume,
    still:f32,   // s an obstacle has not moved
    blocks:bool, // an obstacle that settled: its volume is in the builds
}

Build_Stats :: struct {
    built,emptied,unchanged,discarded:u64, // tiles
    failed:u64,                            // builds that did not finish: input too large, no memory
    overflowed:u64,                        // tiles whose input did not all fit
    dropped:u64,                           // tiles and zones that went with their sections, or in a run with the terrain not loaded
    regions:u64,                           // regions of the coarse graph made
}

// One tile on its way: the job owns it while counter is pending.
@(private)
Build :: struct {
    counter:jobs.Counter,
    busy:bool,
    class:int,
    coord:[2]i32,
    stamp:u32,
    uid:u64,
    hash:u64,
    config:ai.Nav_Build_Config,
    vertices:[dynamic]mm.Vec3,
    indices:[dynamic]u32,
    volumes:[dynamic]ai.Nav_Area_Volume,
    scratch:ai.Nav_Build_Scratch,
    scratch_ready:bool,
    result:ai.Nav_Tile_Data,
    status:ai.Nav_Build_Status,
    // A zone of the air, instead of a tile.
    air:bool,
    zone:[3]i32,
    volume_config:ai.Nav_Volume_Config,
    spaces:[dynamic]mm.Aabb,
    holes:[dynamic]mm.Aabb,
    volume_scratch:ai.Nav_Volume_Scratch,
    volume_scratch_ready:bool,
    zone_result:ai.Nav_Volume_Data,
    ns:i64, // what its job took
}

builds_free :: proc(b:^Navigation_Builds) {
    for build in b.builds {
        // A job may still write it.
        for jobs.pending(&build.counter) {}
        build_release(build)
        free(build)
    }
    delete(b.builds)
    core.entity_map_destroy(&b.areas)
    core.entity_map_destroy(&b.links)
    core.entity_map_destroy(&b.obstacles)
    core.entity_map_destroy(&b.bakes)
    for &paged in b.paged {base.hash_map_destroy(&paged)}
    ai.nav_query_destroy(&b.query)
    ai.nav_volume_query_destroy(&b.volume_query)
    ai.nav_coarse_build_destroy(&b.region)
    delete(b.bounds)
    delete(b.air);delete(b.water);delete(b.dry);delete(b.seen)
    b^={}
}

@(private)
build_release :: proc(build:^Build) {
    delete(build.vertices);delete(build.indices);delete(build.volumes);delete(build.spaces);delete(build.holes)
    ai.nav_build_scratch_destroy(&build.scratch)
    ai.nav_volume_scratch_destroy(&build.volume_scratch)
    ai.nav_tile_data_free(&build.result)
    ai.nav_volume_data_free(&build.zone_result)
}

// How a class is built.
class_config :: proc "contextless" (settings:^Navigation_Settings,class:Nav_Class) -> ai.Nav_Build_Config {
    cs:=settings.cell_size if settings.cell_size>0 else 0.15
    ch:=settings.cell_height if settings.cell_height>0 else 0.1
    return {
        tile_size=settings.tile_cells if settings.tile_cells>0 else 64,
        cell_size=cs,cell_height=ch,
        agent_radius=class.radius,agent_height=class.height,agent_climb=class.climb,agent_max_slope=class.max_slope,
        min_region_area=64,merge_region_area=400,
        max_edge_length=40*cs,max_edge_error=1.3*cs,
        detail_sample_distance=6*cs,detail_max_error=ch,
    }
}

// How a class of the air or the water is built: voxels of a quarter of its thinner
// extent, and zones of 64 of them a side.
volume_config :: proc "contextless" (class:Nav_Class) -> ai.Nav_Volume_Config {
    return {voxel=max(min(class.radius,class.height*0.5)*0.5,0.05),layers=4,half={class.radius,class.height*0.5,class.radius}}
}

@(private)
settings_same :: proc "contextless" (a,b:^Navigation_Settings) -> bool {
    return a.classes==b.classes && a.cell_size==b.cell_size && a.cell_height==b.cell_height && a.tile_cells==b.tile_cells && a.max_tiles==b.max_tiles && a.max_links==b.max_links
}

// Whether every class is made of what the collision settings say blocks its agents now.
@(private)
filters_same :: proc "contextless" (n:^Navigation,collision:^phys.Collision_Settings) -> bool {
    for &c in n.classes[:n.count] {
        if c.filter!=class_filter(collision,c.class) {return false}
    }
    return true
}

// Makes the meshes of the classes of the settings, empty, with every tile in
// the bounds marked, each made of what blocks its agents under collision
// (nil: the defaults). False without memory.
@(private)
navigation_reset :: proc(n:^Navigation,settings:^Navigation_Settings,collision:^phys.Collision_Settings,problems:^core.Problems) -> bool {
    uid:=n.uid
    navigation_free(n)
    n.uid=uid
    n.settings=settings^
    tiles:=int(settings.max_tiles) if settings.max_tiles>0 else 1024
    links:=int(settings.max_links) if settings.max_links>=0 else 0
    for &class in settings.classes {
        if base.text_get(class.name[:])=="" {continue}
        filter:=class_filter(collision,class)
        if class.collision==phys.PRESET_CUSTOM || filter.filter.block==0 {
            core.report(problems,core.NONE,"navigation.class","The class %q of Navigation_Settings takes collision preset %d, which blocks nothing: give it the preset of the colliders of its agents (not Custom nor a sensor). It has no mesh",base.text_get(class.name[:]),class.collision)
            continue
        }
        if class.space!=.Surface {
            if !(class.radius>0) || !(class.height>0) || class.radius>1e3 || class.height>1e3 {
                core.report(problems,core.NONE,"navigation.class","The class %q of Navigation_Settings needs a radius and a height above 0 and below 1000 m: it has no volume",base.text_get(class.name[:]))
                continue
            }
            c:=&n.classes[n.count]
            c.class,c.filter=class,filter
            c.volume_config=volume_config(class)
            if !ai.nav_volume_init(&c.volume,{voxel=c.volume_config.voxel,layers=c.volume_config.layers,max_zones=min(tiles,ai.NAV_VOLUME_SLOT_MAX)}) || !base.hash_map_init(&c.marks,tiles) {
                navigation_free(n)
                n.uid=uid
                return false
            }
            n.count+=1
            continue
        }
        if !(class.radius>0) || !(class.height>0) || !(class.climb>=0) || !(class.max_slope>0 && class.max_slope<0.5*mm.PI) {
            core.report(problems,core.NONE,"navigation.class","The class %q of Navigation_Settings needs a radius and a height above 0, a climb of 0 or more and a slope between 0 and 90 degrees: it has no mesh",base.text_get(class.name[:]))
            continue
        }
        c:=&n.classes[n.count]
        c.class,c.filter=class,filter
        c.config=class_config(settings,class)
        width:=f32(c.config.tile_size)*c.config.cell_size
        if !ai.nav_mesh_init(&c.mesh,{tile_width=width,climb=class.climb,max_tiles=tiles,max_links=links}) || !base.hash_map_init(&c.marks,tiles) {
            navigation_free(n)
            n.uid=uid
            return false
        }
        n.count+=1
    }
    n.ready=true
    n.revision+=1
    return true
}

// Marks the tiles and zones of every class that a box touches, with the
// margin their build reads around them; only tiles for what changes only the
// surface (areas, obstacles).
@(private)
mark_box :: proc(n:^Navigation,box:mm.Aabb,limits:Limits,force:=false,air:=true) {
    for i in 0..<n.count {
        c:=&n.classes[i]
        if class_in_volume(n,i) {
            if air {mark_zones(c,box,limits_of(c,limits),force)}
            continue
        }
        margin:=ai.nav_build_margin(c.config)
        grown:=mm.aabb_expand(box,margin)
        low,high:=ai.nav_mesh_coord(&c.mesh,grown.min),ai.nav_mesh_coord(&c.mesh,grown.max)
        if i64(high.x)-i64(low.x)>4096 || i64(high.y)-i64(low.y)>4096 {continue}
        for z in low.y..=high.y {
            for x in low.x..=high.x {
                coord:=[2]i32{x,z}
                if !tile_inside(c,coord,limits.surface) && ai.nav_mesh_tile_at(&c.mesh,coord)==nil {continue}
                mark,_:=base.hash_map_insert(&c.marks,coord_key(coord))
                if mark==nil {continue}
                mark_set(c,mark,marked(mark^,force))
            }
        }
    }
}

@(private)
mark_zones :: proc(c:^Class_Mesh,box:mm.Aabb,air:[]mm.Aabb,force:bool) {
    margin:=c.volume_config.half+c.volume_config.voxel
    low,high:=ai.nav_volume_coord(&c.volume,box.min-margin),ai.nav_volume_coord(&c.volume,box.max+margin)
    if i64(high.x-low.x+1)*i64(high.y-low.y+1)*i64(high.z-low.z+1)>1<<16 {return}
    for z in low.z..=high.z {
        for y in low.y..=high.y {
            for x in low.x..=high.x {
                coord:=[3]i32{x,y,z}
                if !zone_inside(c,coord,air) && ai.nav_volume_zone_at(&c.volume,coord)==nil {continue}
                mark,_:=base.hash_map_insert(&c.marks,zone_key(coord))
                if mark==nil {continue}
                mark_set(c,mark,marked(mark^,force))
            }
        }
    }
}

// A mark marked again: it waits for a build, and looks again at whether its collision is loaded.
@(private)
marked :: proc "contextless" (mark:Tile_Mark,force:bool) -> Tile_Mark {
    next:=mark
    next.dirty,next.unloaded=true,false
    next.stamp+=1
    if force {next.hash=0}
    return next
}

@(private)
zone_inside :: proc "contextless" (c:^Class_Mesh,coord:[3]i32,air:[]mm.Aabb) -> bool {
    box:=ai.nav_volume_zone_box(&c.volume,coord)
    for limit in air {if mm.aabb_overlaps(box,limit) {return true}}
    return false
}

// Whether a tile lies in the bounds where meshes are made.
@(private)
tile_inside :: proc "contextless" (c:^Class_Mesh,coord:[2]i32,limits:[]mm.Aabb) -> bool {
    rect:=ai.nav_tile_rect(c.config,coord)
    for limit in limits {
        if rect.max.x>limit.min.x && rect.min.x<limit.max.x && rect.max.z>limit.min.z && rect.min.z<limit.max.z {return true}
    }
    return false
}

// The world box of an upright box in the frame of an entity.
@(private)
upright_box :: proc "contextless" (pose:mm.Transform,half:[3]f32) -> (box:mm.Aabb,corners:[4][2]f32) {
    h:=half*pose.scale
    box=mm.AABB_EMPTY
    signs:=[4][2]f32{{-1,-1},{1,-1},{1,1},{-1,1}}
    for sign,i in signs {
        p:=pose.position+mm.quat_rotate(pose.rotation,mm.Vec3{sign.x*h.x,0,sign.y*h.z})
        corners[i]={p.x,p.z}
        box=mm.aabb_add_point(box,p-{0,h.y,0})
        box=mm.aabb_add_point(box,p+{0,h.y,0})
    }
    // Counter-clockwise on (x, z up) whatever the turn: a mirror would wind them the other way.
    if (corners[1].x-corners[0].x)*(corners[2].y-corners[0].y)-(corners[1].y-corners[0].y)*(corners[2].x-corners[0].x)<0 {
        corners[1],corners[3]=corners[3],corners[1]
    }
    return
}

@(step="fixed",loops="game editor",stage="react",server)
navigation_build :: proc(
    n:^Navigation,b:^Navigation_Builds,settings:core.Ref(Navigation_Settings),bakes:core.Read(Navigation_Bake),physics:core.Ref(phys.Physics_State),requests:^Nav_Build_Requests,
    bounds:core.Read(Nav_Bounds),areas:core.Read(Nav_Area),links:core.Read(Nav_Link),obstacles:core.Read(Nav_Obstacle),time:core.Time,transforms:core.Read(core.Transform),parents:core.Read(core.Parent),
    unloaded:core.Ref(Nav_Unloaded),references:core.Read(scene.Scene_Reference),worlds:core.Read(core.World_Transform),ids:core.Read(core.Id),app:^host.App,problems:^core.Problems,
) {
    if physics.ptr==nil || !physics.ready || settings.ptr==nil {return}
    // A section away is not loaded: like the terrain that is not, its tiles wait for it.
    b.sections=sections_gather(references,worlds,ids)
    gone:=Unloaded{unloaded.ptr,&b.sections,base.hash_combine(unloaded.ptr.revision if unloaded.ptr!=nil else 0,b.sections.hash)}
    fresh,reset:=false,false
    // A class is made again when it changes, or when what blocks its agents does (Collision_Settings).
    collision:=&physics.ptr.collision
    if !n.ready || !settings_same(&n.settings,settings.ptr) || !filters_same(n,collision) {
        if !navigation_reset(n,settings.ptr,collision,problems) {
            core.report(problems,core.NONE,"navigation.memory","No memory for the navigation meshes of Navigation_Settings: lower max_tiles or max_links")
            return
        }
        core.entity_map_clear(&b.bakes)
        b.bakes_seen=0
        fresh,reset=true,true
    }
    // What changes no mesh (area costs, budgets) takes effect at once.
    if n.settings!=settings.ptr^ {n.settings=settings.ptr^}
    if n.uid==0 || n.uid!=b.uid {
        // Another copy of the world, or the first look: what is building was for another.
        b.next_uid+=1
        n.uid=b.next_uid
        b.uid=n.uid
        core.entity_map_clear(&b.areas)
        core.entity_map_clear(&b.links)
        core.entity_map_clear(&b.obstacles)
        for build in b.builds {if build.busy {build.uid=0}}
        b.region_busy=false
        // A copy has the meshes of the bakes of its world already.
        if !reset {core.entity_map_clear(&b.bakes)}
        b.bakes_seen=0
        fresh=true
    }
    bakes_update(n,b,bakes,app,problems,fresh && !reset)
    next,count,overflow:=phys.static_changes(physics,b.cursor,b.boxes[:])
    limits:=bounds_update(n,b,bounds,transforms,parents,physics,gone,fresh,count>0 || overflow)
    if fresh {
        for limit in limits.surface {mark_box(n,limit,limits)}
        for limit in limits.air {mark_box(n,limit,limits)}
    }
    areas_update(n,b,areas,transforms,parents,limits,fresh)
    obstacles_update(n,b,obstacles,transforms,parents,limits,time,fresh)
    for asked in core.take(&requests.queue) {
        if asked.box=={} {
            for limit in limits.surface {mark_box(n,limit,limits,true)}
            for limit in limits.air {mark_box(n,limit,limits,true)}
        } else {mark_box(n,asked.box,limits,true)}
    }
    // Where the static collision changed in this tick, for the arcs of the links over it.
    changed:=mm.AABB_EMPTY
    for {
        b.cursor=next
        if overflow {
            for limit in limits.surface {mark_box(n,limit,limits)}
            for limit in limits.air {mark_box(n,limit,limits)}
            changed={-max(f32),max(f32)}
        }
        for box in b.boxes[:count] {
            mark_box(n,box,limits)
            changed=mm.aabb_merge(changed,box)
        }
        if count<len(b.boxes) {break}
        next,count,overflow=phys.static_changes(physics,b.cursor,b.boxes[:])
    }
    sections_update(n,b,limits,fresh)
    paging_update(n,b,unloaded.ptr,time.playing,fresh,reset,app,problems)
    published,spent:=builds_publish(n,b,problems)
    host.load_phase_add(app,.Nav_Tiles,spent,published)
    builds_start(n,b,physics,limits,gone,time.playing,app,problems)
    // Tiles building keep a load from being resident.
    building:=false
    for build in b.builds {building||=build.busy}
    host.load_report(app,.Navigation,building)
    links_update(n,b,links,transforms,parents,physics,changed,fresh,problems)
    links_generate(n,physics,problems)
    coarse_update(n,b,problems)
}

// The bounds where meshes are made: those of the Nav_Bounds, or the box of
// the static collision and of where it is not loaded, which does not shrink
// when a terrain lets its colliders go; those of the air; and the water of the
// Fluid_Volume rows, up to its surface, a plane within the bounds of the
// surface, with its dry boxes. Tiles and zones that leave them are removed;
// those that enter are marked.
@(private)
bounds_update :: proc(n:^Navigation,b:^Navigation_Builds,bounds:core.Read(Nav_Bounds),transforms:core.Read(core.Transform),parents:core.Read(core.Parent),physics:core.Ref(phys.Physics_State),unloaded:Unloaded,fresh,collision_changed:bool) -> Limits {
    // The water and the box of the collision change with the collision, through its change log.
    poses:=poses_stamps(bounds,transforms,parents)
    stamps:=[7]u64{poses[0],poses[1],poses[2],poses[3],poses[4],poses[5],unloaded.revision}
    if !fresh && !collision_changed && stamps==b.bounds_stamps {return {b.bounds[:],b.air[:],b.water[:],b.dry[:]}}
    b.bounds_stamps=stamps
    surface,air:[64]mm.Aabb
    count,count_air:=0,0
    for i in 0..<core.count(bounds) {
        e:=core.entity_at(bounds,i)
        pose,ok:=core.world_of(transforms,parents,e)
        if !ok {continue}
        bound:=bounds.table.values[i]
        box,_:=upright_box(pose,bound.half)
        if bound.air {
            if count_air<len(air) {air[count_air]=box;count_air+=1}
        } else if count<len(surface) {surface[count]=box;count+=1}
    }
    if count==0 {
        box,ok:=phys.static_bounds(physics)
        if !ok {box=mm.AABB_EMPTY}
        if unloaded.terrain!=nil {for gone in unloaded.terrain.boxes {box=mm.aabb_merge(box,gone)}}
        if unloaded.sections!=nil {for gone in unloaded.sections.away[:unloaded.sections.away_count] {box=mm.aabb_merge(box,gone)}}
        if !mm.aabb_is_empty(box) {surface[0]=box;count=1}
    }
    water,dry:[64]mm.Aabb
    count_water,count_dry:=0,0
    fluids:[64]phys.Fluid_Info
    far:=f32(1e30)
    for info in fluids[:min(phys.fluids_in(physics,{{-far,-far,-far},{far,far,far}},fluids[:]),len(fluids))] {
        if info.desc.density<=0 {
            if count_dry<len(dry) {dry[count_dry]=info.bounds;count_dry+=1}
        } else if info.desc.shape==.Box {
            if count_water<len(water) {water[count_water]=info.bounds;count_water+=1}
        } else {
            for limit in surface[:count] {
                box:=mm.Aabb{limit.min,{limit.max.x,min(limit.max.y,info.top),limit.max.z}}
                if box.max.y>box.min.y && count_water<len(water) {water[count_water]=box;count_water+=1}
            }
        }
    }
    same :: proc(current:[]mm.Aabb,kept:[dynamic]mm.Aabb) -> bool {
        if len(current)!=len(kept) {return false}
        for box,i in current {if box!=kept[i] {return false}}
        return true
    }
    if same(surface[:count],b.bounds) && same(air[:count_air],b.air) && same(water[:count_water],b.water) && same(dry[:count_dry],b.dry) && !fresh {
        return {b.bounds[:],b.air[:],b.water[:],b.dry[:]}
    }
    previous:=make([]mm.Aabb,len(b.bounds),context.temp_allocator)
    copy(previous,b.bounds[:])
    previous_air:=make([]mm.Aabb,len(b.air),context.temp_allocator)
    copy(previous_air,b.air[:])
    previous_water:=make([]mm.Aabb,len(b.water),context.temp_allocator)
    copy(previous_water,b.water[:])
    previous_dry:=make([]mm.Aabb,len(b.dry),context.temp_allocator)
    copy(previous_dry,b.dry[:])
    resize(&b.bounds,count)
    copy(b.bounds[:],surface[:count])
    resize(&b.air,count_air)
    copy(b.air[:],air[:count_air])
    resize(&b.water,count_water)
    copy(b.water[:],water[:count_water])
    resize(&b.dry,count_dry)
    copy(b.dry[:],dry[:count_dry])
    limits:=Limits{b.bounds[:],b.air[:],b.water[:],b.dry[:]}
    if fresh {return limits}
    // Tiles and zones outside the new bounds go; the new parts are marked.
    for i in 0..<n.count {
        c:=&n.classes[i]
        if class_in_volume(n,i) {
            for &zone in c.volume.zones {
                if zone.used && !zone_inside(c,zone.data.coord,limits_of(c,limits)) {
                    coord:=zone.data.coord
                    ai.nav_volume_remove_zone(&c.volume,coord)
                    mark_remove(c,zone_key(coord))
                    n.revision+=1
                }
            }
            continue
        }
        for &tile in c.mesh.tiles {
            if tile.used && !tile_inside(c,tile.data.coord,limits.surface) {
                coord:=tile.data.coord
                ai.nav_mesh_remove_tile(&c.mesh,coord)
                mark_remove(c,coord_key(coord))
                links_mark(n,i,coord)
                n.revision+=1
            }
        }
    }
    mark_new :: proc(n:^Navigation,boxes,previous:[]mm.Aabb,limits:Limits) {
        for box in boxes {
            inside:=false
            for old in previous {if old==box {inside=true;break}}
            if !inside {mark_box(n,box,limits)}
        }
    }
    mark_new(n,limits.surface,previous,limits)
    mark_new(n,limits.air,previous_air,limits)
    mark_new(n,limits.water,previous_water,limits)
    mark_new(n,limits.dry,previous_dry,limits)
    // What a box that went covered is built again too.
    mark_new(n,previous_water,limits.water,limits)
    mark_new(n,previous_dry,limits.dry,limits)
    return limits
}

// Marks where a Nav_Area was and is, when it moved, changed or went.
@(private)
areas_update :: proc(n:^Navigation,b:^Navigation_Builds,areas:core.Read(Nav_Area),transforms:core.Read(core.Transform),parents:core.Read(core.Parent),limits:Limits,fresh:bool) {
    stamps:=poses_stamps(areas,transforms,parents)
    if !fresh && stamps==b.areas_stamps {return}
    b.areas_stamps=stamps
    seen:=seen_reset(b,len(b.areas.values))
    for i in 0..<core.count(areas) {
        e:=core.entity_at(areas,i)
        pose,ok:=core.world_of(transforms,parents,e)
        if !ok {continue}
        area:=areas.table.values[i]
        box,corners:=upright_box(pose,area.half)
        now:=Area_Seen{box=box,volume={count=4,area=u8(area.area),min_y=box.min.y,max_y=box.max.y}}
        for corner,k in corners {now.volume.points[k]=corner}
        at:=core.entity_map_index(&b.areas,e)
        if at>=0 {
            if at<len(seen) {seen[at]=true}
            if b.areas.values[at]!=now {
                if !fresh {mark_box(n,b.areas.values[at].box,limits,air=false);mark_box(n,box,limits,air=false)}
                b.areas.values[at]=now
            }
            continue
        }
        core.entity_map_put(&b.areas,e,now)
        if !fresh {mark_box(n,box,limits,air=false)}
    }
    for at:=len(seen)-1;at>=0;at-=1 {
        if seen[at] {continue}
        mark_box(n,b.areas.values[at].box,limits,air=false)
        core.entity_map_remove_at(&b.areas,at)
    }
}

// Gathers, hashes and starts the builds of marked tiles, up to the free jobs.
@(private)
builds_start :: proc(n:^Navigation,b:^Navigation_Builds,physics:core.Ref(phys.Physics_State),limits:Limits,unloaded:Unloaded,playing:bool,app:^host.App,problems:^core.Problems) {
    want:=int(n.settings.builds) if n.settings.builds>0 else 4
    for len(b.builds)<want {
        build,error:=new(Build)
        if error!=nil {break}
        append(&b.builds,build)
    }
    checks:=0
    // The marks that wait for their collision are looked at again when what is not loaded changes.
    revision:=unloaded.revision
    loaded:=revision!=b.unloaded_seen
    paging:=unloaded.terrain.boxes[:] if playing && unloaded.terrain!=nil else nil
    for i in 0..<n.count {
        c:=&n.classes[i]
        if c.ready==0 && (c.loading==0 || !loaded) {continue}
        it:=base.hash_map_iterator(&c.marks)
        for key,mark in base.hash_map_iterate(&it) {
            if !mark.dirty || mark.building {continue}
            // What it reads is not all loaded: it keeps what it has and waits. With nothing to
            // keep where only away sections are, it waits for nothing: a change there marks it
            // again; nor in a run where only the terrain not loaded is, kept to mark when it loads.
            volume:=class_in_volume(n,i)
            box:=mark_box_of(c,key,volume)
            if waits:=unloaded_overlaps(unloaded,box,!volume);waits!=mark.unloaded {
                next:=mark^
                next.unloaded=waits
                mark_set(c,mark,next)
            }
            if mark.unloaded {
                kept:=ai.nav_volume_zone_at(&c.volume,zone_of_key(key))!=nil if volume else ai.nav_mesh_tile_at(&c.mesh,coord_of_key(key))!=nil
                if !kept && (sections_covered(&b.sections,box,!volume) || boxes_cover(paging,box,!volume) && paged_put(&b.paged[i],key,0)) {
                    next:=mark^
                    next.dirty,next.unloaded=false,false
                    mark_set(c,mark,next)
                }
                continue
            }
            if checks>=NAV_CHECKS_PER_TICK {return}
            free:^Build
            for build in b.builds {if !build.busy {free=build;break}}
            if free==nil {return}
            checks+=1
            next:=mark^
            next.dirty=false
            mark_set(c,mark,next)
            if class_in_volume(n,i) {
                zone:=zone_of_key(key)
                if !zone_inside(c,zone,limits_of(c,limits)) {
                    if ai.nav_volume_remove_zone(&c.volume,zone) {n.revision+=1}
                    mark.hash=0
                    continue
                }
                if !gather_zone(free,c,b,physics,zone) {
                    n.stats.overflowed+=1
                    core.report(problems,core.NONE,"navigation.zone_input","A zone of class %q at %v has more than %d triangles of static collision: it is built from part of them",base.text_get(c.class.name[:]),zone,NAV_TRIANGLES_MAX)
                }
                if free.hash==mark.hash {n.stats.unchanged+=1;continue}
                free.busy,free.class,free.air,free.zone,free.stamp,free.uid=true,i,true,zone,mark.stamp,n.uid
                free.volume_config=c.volume_config
                next.building=true
                mark_set(c,mark,next)
                build_launch(free,app)
                continue
            }
            coord:=coord_of_key(key)
            if !tile_inside(c,coord,limits.surface) {
                if ai.nav_mesh_remove_tile(&c.mesh,coord) {n.revision+=1;links_mark(n,i,coord)}
                mark.hash=0
                continue
            }
            if !gather(free,n,c,b,physics,coord,problems) {
                n.stats.overflowed+=1
                core.report(problems,core.NONE,"navigation.tile_input","A tile of class %q at %v has more than %d triangles of static collision: it is built from part of them; lower tile_cells in Navigation_Settings",base.text_get(n.classes[i].class.name[:]),coord,NAV_TRIANGLES_MAX)
            }
            if free.hash==mark.hash {n.stats.unchanged+=1;continue}
            free.busy,free.class,free.air,free.coord,free.stamp,free.uid=true,i,false,coord,mark.stamp,n.uid
            free.config=c.config
            next.building=true
            mark_set(c,mark,next)
            build_launch(free,app)
        }
    }
    b.unloaded_seen=revision
}

// The box a tile or a zone reads to build: with the margin of its class, and every height for a tile.
@(private)
mark_box_of :: proc "contextless" (c:^Class_Mesh,key:u64,air:bool) -> mm.Aabb {
    if air {
        box:=ai.nav_volume_zone_box(&c.volume,zone_of_key(key))
        margin:=c.volume_config.half+c.volume_config.voxel
        return {box.min-margin,box.max+margin}
    }
    rect:=ai.nav_tile_rect(c.config,coord_of_key(key))
    margin:=ai.nav_build_margin(c.config)
    return {{rect.min.x-margin,-max(f32),rect.min.z-margin},{rect.max.x+margin,max(f32),rect.max.z+margin}}
}

@(private)
build_launch :: proc(build:^Build,app:^host.App) {
    if jobs.worker_count(&app.jobs)==0 {
        build_job(build,0)
        return
    }
    jobs.run(&app.jobs,jobs.OWNER,build_job,build,&build.counter)
    if jobs.worker_count(&app.jobs)==1 {jobs.wait(&app.jobs,jobs.OWNER,&build.counter)}
}

// The triangles of the static collision in a box that block filter (the
// agents of a class) into a build, up to NAV_TRIANGLES_MAX. False when not
// all of them fit.
@(private)
gather_triangles :: proc(build:^Build,physics:core.Ref(phys.Physics_State),box:mm.Aabb,filter:phys.Query_Filter) -> bool {
    size:=4096
    for {
        resize(&build.vertices,size)
        resize(&build.indices,size*2)
        vertex_count,index_count,fit:=phys.static_triangles(physics,box,transmute([][3]f32)build.vertices[:],build.indices[:],filter)
        if fit || size>=NAV_TRIANGLES_MAX {
            resize(&build.vertices,vertex_count)
            resize(&build.indices,index_count)
            return fit
        }
        size*=4
    }
}

// The input of a zone into a build, and its hash: the collision the zone,
// grown by the half size of its class, touches, the bounds of the air or the
// water that hold it and the dry boxes in that water. False when not all of
// it fit.
@(private)
gather_zone :: proc(build:^Build,c:^Class_Mesh,b:^Navigation_Builds,physics:core.Ref(phys.Physics_State),zone:[3]i32) -> bool {
    box:=ai.nav_volume_zone_box(&c.volume,zone)
    margin:=c.volume_config.half+c.volume_config.voxel
    complete:=gather_triangles(build,physics,{box.min-margin,box.max+margin},c.filter)
    clear(&build.spaces)
    clear(&build.holes)
    water:=c.class.space==.Water
    for limit in (b.water if water else b.air) {if mm.aabb_overlaps(limit,box) {append(&build.spaces,limit)}}
    if water {for hole in b.dry {if mm.aabb_overlaps({hole.min-margin,hole.max+margin},box) {append(&build.holes,hole)}}}
    config:=c.volume_config
    h:=base.hash64(mem.ptr_to_bytes(&config),0)
    h=base.hash64(mem.ptr_to_bytes(&box),h)
    h=base.hash64(mem.slice_to_bytes(build.vertices[:]),h)
    h=base.hash64(mem.slice_to_bytes(build.indices[:]),h)
    h=base.hash64(mem.slice_to_bytes(build.spaces[:]),h)
    h=base.hash64(mem.slice_to_bytes(build.holes[:]),h)
    build.hash=h|1
    return complete
}

// The input of a tile into a build, and its hash. False when not all of it fit.
@(private)
gather :: proc(build:^Build,n:^Navigation,c:^Class_Mesh,b:^Navigation_Builds,physics:core.Ref(phys.Physics_State),coord:[2]i32,problems:^core.Problems) -> bool {
    rect:=ai.nav_tile_rect(c.config,coord)
    margin:=ai.nav_build_margin(c.config)
    box:=mm.Aabb{{rect.min.x-margin,-1e9,rect.min.z-margin},{rect.max.x+margin,1e9,rect.max.z+margin}}
    for limit in b.bounds {
        box.min.y=min(box.min.y if box.min.y>-1e9 else limit.min.y,limit.min.y)
        box.max.y=max(box.max.y if box.max.y<1e9 else limit.max.y,limit.max.y)
    }
    complete:=gather_triangles(build,physics,box,c.filter)
    clear(&build.volumes)
    // The deep ground under the water first: an area of a Nav_Area or an obstacle there wins.
    for water in b.water {
        if water.max.x<rect.min.x-margin || water.min.x>rect.max.x+margin || water.max.z<rect.min.z-margin || water.min.z>rect.max.z+margin {continue}
        deep:=water.max.y-phys.SWIM_DEFAULT.depth
        if !(deep>water.min.y) {continue}
        volume:=ai.Nav_Area_Volume{count=4,area=u8(AREA_WATER),min_y=water.min.y,max_y=deep}
        volume.points[0],volume.points[1],volume.points[2],volume.points[3]={water.min.x,water.min.z},{water.max.x,water.min.z},{water.max.x,water.max.z},{water.min.x,water.max.z}
        append(&build.volumes,volume)
    }
    for seen in b.areas.values {
        box:=seen.box
        if box.max.x<rect.min.x-margin || box.min.x>rect.max.x+margin || box.max.z<rect.min.z-margin || box.min.z>rect.max.z+margin {continue}
        append(&build.volumes,seen.volume)
    }
    // Obstacles after the areas: blocked wins.
    for seen in b.obstacles.values {
        box:=seen.box
        if !seen.blocks || box.max.x<rect.min.x-margin || box.min.x>rect.max.x+margin || box.max.z<rect.min.z-margin || box.min.z>rect.max.z+margin {continue}
        append(&build.volumes,seen.volume)
    }
    config:=c.config
    h:=base.hash64(mem.ptr_to_bytes(&config),0)
    h=base.hash64(mem.slice_to_bytes(build.vertices[:]),h)
    h=base.hash64(mem.slice_to_bytes(build.indices[:]),h)
    h=base.hash64(mem.slice_to_bytes(build.volumes[:]),h)
    build.hash=h|1
    return complete
}

@(private)
build_job :: proc(build:^Build,worker:int) {
    started:=time.tick_now()
    defer build.ns=time.duration_nanoseconds(time.tick_since(started))
    if build.air {
        if !build.volume_scratch_ready {ai.nav_volume_scratch_init(&build.volume_scratch);build.volume_scratch_ready=true}
        ai.nav_volume_data_free(&build.zone_result)
        build.status=ai.nav_volume_build(build.volume_config,build.zone,{vertices=build.vertices[:],indices=build.indices[:],spaces=build.spaces[:],holes=build.holes[:]},&build.volume_scratch,&build.zone_result)
        return
    }
    if !build.scratch_ready {ai.nav_build_scratch_init(&build.scratch);build.scratch_ready=true}
    ai.nav_tile_data_free(&build.result)
    build.status=ai.nav_build_tile(build.config,build.coord,{vertices=build.vertices[:],indices=build.indices[:],volumes=build.volumes[:]},&build.scratch,&build.result)
}

// Puts the tiles of finished builds in their meshes, when they are still
// what the tile needs: how many builds ended and what their jobs took.
@(private)
builds_publish :: proc(n:^Navigation,b:^Navigation_Builds,problems:^core.Problems) -> (ended:int,ns:i64) {
    for build in b.builds {
        if !build.busy || jobs.pending(&build.counter) {continue}
        build.busy=false
        ended+=1
        ns+=build.ns
        defer ai.nav_tile_data_free(&build.result)
        defer ai.nav_volume_data_free(&build.zone_result)
        if build.uid!=n.uid || build.class>=n.count {n.stats.discarded+=1;continue}
        c:=&n.classes[build.class]
        if build.air {
            zone_publish(n,c,build,problems)
            continue
        }
        mark:=base.hash_map_ptr(&c.marks,coord_key(build.coord))
        if mark==nil {n.stats.discarded+=1;continue}
        built:=mark^
        built.building=false
        mark_set(c,mark,built)
        if mark.stamp!=build.stamp {n.stats.discarded+=1;continue}
        switch build.status {
        case .Built:
            build.result.hash=build.hash
            if ai.nav_mesh_add_tile(&c.mesh,build.result) {
                build.result={}
                mark.hash=build.hash
                n.stats.built+=1
                n.revision+=1
                links_mark(n,build.class,build.coord)
            } else {
                n.stats.failed+=1
                core.report(problems,core.NONE,"navigation.tiles","The mesh of class %q has no room for another tile: raise max_tiles in Navigation_Settings",base.text_get(n.classes[build.class].class.name[:]))
            }
        case .Empty:
            if ai.nav_mesh_remove_tile(&c.mesh,build.coord) {n.revision+=1;links_mark(n,build.class,build.coord)}
            mark.hash=build.hash
            n.stats.emptied+=1
        case .Invalid,.Out_Of_Memory,.Too_Large:
            n.stats.failed+=1
            core.report(problems,core.NONE,"navigation.build","A tile of class %q at %v failed to build (%v): check its class in Navigation_Settings and the collision there",base.text_get(n.classes[build.class].class.name[:]),build.coord,build.status)
        }
    }
    return
}

@(private)
zone_publish :: proc(n:^Navigation,c:^Class_Mesh,build:^Build,problems:^core.Problems) {
    mark:=base.hash_map_ptr(&c.marks,zone_key(build.zone))
    if mark==nil {n.stats.discarded+=1;return}
    built:=mark^
    built.building=false
    mark_set(c,mark,built)
    if mark.stamp!=build.stamp {n.stats.discarded+=1;return}
    switch build.status {
    case .Built:
        build.zone_result.hash=build.hash
        if ai.nav_volume_add_zone(&c.volume,build.zone_result) {
            build.zone_result={}
            mark.hash=build.hash
            n.stats.built+=1
            n.revision+=1
        } else {
            n.stats.failed+=1
            core.report(problems,core.NONE,"navigation.tiles","The volume of class %q has no room for another zone: raise max_tiles in Navigation_Settings",base.text_get(c.class.name[:]))
        }
    case .Empty:
        if ai.nav_volume_remove_zone(&c.volume,build.zone) {n.revision+=1}
        mark.hash=build.hash
        n.stats.emptied+=1
    case .Invalid,.Out_Of_Memory,.Too_Large:
        n.stats.failed+=1
        core.report(problems,core.NONE,"navigation.build","A zone of class %q at %v failed to build (%v): check its class in Navigation_Settings",base.text_get(c.class.name[:]),build.zone,build.status)
    }
}

// Obstacles block the surface under them once they have been still long
// enough, and stop when they move; outside a run (the editor) they are still.
@(private)
obstacles_update :: proc(n:^Navigation,b:^Navigation_Builds,obstacles:core.Read(Nav_Obstacle),transforms:core.Read(core.Transform),parents:core.Read(core.Parent),limits:Limits,time:core.Time,fresh:bool) {
    stamps:=poses_stamps(obstacles,transforms,parents)
    moved:=fresh || stamps!=b.obstacles_stamps
    // Unmoved, only those that settle need the tick.
    if !moved && b.settling==0 {return}
    b.obstacles_stamps=stamps
    seen:=seen_reset(b,len(b.obstacles.values) if moved else 0)
    running:=time.playing && time.dt>0
    b.settling=0
    for i in 0..<core.count(obstacles) {
        e:=core.entity_at(obstacles,i)
        obstacle:=obstacles.table.values[i]
        at:=core.entity_map_index(&b.obstacles,e)
        if moved {
            pose,ok:=core.world_of(transforms,parents,e)
            if !ok {continue}
            box,corners:=upright_box(pose,obstacle.half)
            volume:=ai.Nav_Area_Volume{count=4,area=ai.NAV_AREA_BLOCKED,min_y=box.min.y,max_y=box.max.y}
            for corner,k in corners {volume.points[k]=corner}
            if at<0 {
                core.entity_map_put(&b.obstacles,e,Area_Seen{box=box,volume=volume})
                at=core.entity_map_index(&b.obstacles,e)
                if at<0 {continue}
            } else if at<len(seen) {seen[at]=true}
            o:=&b.obstacles.values[at]
            if o.box!=box {
                if o.blocks {mark_box(n,o.box,limits,air=false)}
                o.box,o.volume,o.still,o.blocks=box,volume,0,false
            }
        } else if at<0 {continue}
        o:=&b.obstacles.values[at]
        o.still+=time.dt if running else obstacle.settle
        if !o.blocks && o.still>=obstacle.settle {
            o.blocks=true
            mark_box(n,o.box,limits,air=false)
        }
        if !o.blocks {b.settling+=1}
    }
    for at:=len(seen)-1;at>=0;at-=1 {
        if seen[at] {continue}
        if b.obstacles.values[at].blocks {mark_box(n,b.obstacles.values[at].box,limits,air=false)}
        core.entity_map_remove_at(&b.obstacles,at)
    }
}

// When the sections change: what a section that comes back covers is marked,
// to build or to check what its bake put there; the tiles and zones where
// only away sections are go, with what marks them.
@(private)
sections_update :: proc(n:^Navigation,b:^Navigation_Builds,limits:Limits,fresh:bool) {
    s:=&b.sections
    if s.hash==b.sections_seen && !fresh {return}
    b.sections_seen=s.hash
    for old in b.away[:b.away_count] {
        still:=false
        for box in s.away[:s.away_count] {if box==old {still=true;break}}
        if !still {mark_box(n,old,limits)}
    }
    b.away,b.away_count=s.away,s.away_count
    if s.away_count==0 {return}
    gone:=make([dynamic]u64,context.temp_allocator)
    for i in 0..<n.count {
        c:=&n.classes[i]
        volume:=class_in_volume(n,i)
        if volume {
            for &zone in c.volume.zones {
                if !zone.used || !sections_covered(s,ai.nav_volume_zone_box(&c.volume,zone.data.coord)) {continue}
                coord:=zone.data.coord
                ai.nav_volume_remove_zone(&c.volume,coord)
                mark_remove(c,zone_key(coord))
                n.stats.dropped+=1
                n.revision+=1
            }
        } else {
            for &tile in c.mesh.tiles {
                if !tile.used || !sections_covered(s,tile.data.bounds) {continue}
                coord:=tile.data.coord
                ai.nav_mesh_remove_tile(&c.mesh,coord)
                ai.nav_mesh_remove_links_of(&c.mesh,generated_owner(coord))
                mark_remove(c,coord_key(coord))
                links_mark(n,i,coord)
                n.stats.dropped+=1
                n.revision+=1
            }
        }
        // Marks with nothing to keep there wait for nothing.
        clear(&gone)
        it:=base.hash_map_iterator(&c.marks)
        for key,mark in base.hash_map_iterate(&it) {
            if mark.building {continue}
            kept:=ai.nav_volume_zone_at(&c.volume,zone_of_key(key))!=nil if volume else ai.nav_mesh_tile_at(&c.mesh,coord_of_key(key))!=nil
            if !kept && sections_covered(s,mark_box_of(c,key,volume),!volume) {append(&gone,key)}
        }
        for key in gone {mark_remove(c,key)}
    }
}

// In a run, the tiles and zones that read only where the terrain is not
// loaded (Nav_Unloaded) go, as those of a section away, and are kept in
// paged; when what is not loaded changes, those it no longer covers come back
// from the bakes of the world, and are marked to build what the bakes do not
// have or what changed. The edited world keeps them all: the editor bakes its
// meshes.
@(private)
paging_update :: proc(n:^Navigation,b:^Navigation_Builds,unloaded:^Nav_Unloaded,playing,fresh,reset:bool,app:^host.App,problems:^core.Problems) {
    if reset {for &paged in b.paged {base.hash_map_clear(&paged)}}
    seen:=base.hash_combine(unloaded.revision if unloaded!=nil else 0,u64(playing))
    if seen==b.paged_seen && !fresh {return}
    b.paged_seen=seen
    boxes:=unloaded.boxes[:] if playing && unloaded!=nil else nil
    paging_restore(n,b,boxes,app,problems)
    if len(boxes)==0 {return}
    gone:=make([dynamic]u64,context.temp_allocator)
    for i in 0..<n.count {
        c:=&n.classes[i]
        volume:=class_in_volume(n,i)
        paged:=&b.paged[i]
        if volume {
            for &zone in c.volume.zones {
                if !zone.used {continue}
                coord:=zone.data.coord
                key:=zone_key(coord)
                if !boxes_cover(boxes,mark_box_of(c,key,true)) || !paged_put(paged,key,zone.data.hash) {continue}
                ai.nav_volume_remove_zone(&c.volume,coord)
                mark_remove(c,key)
                n.stats.dropped+=1
                n.revision+=1
            }
        } else {
            for &tile in c.mesh.tiles {
                if !tile.used {continue}
                coord:=tile.data.coord
                key:=coord_key(coord)
                if !boxes_cover(boxes,mark_box_of(c,key,false),true) || !paged_put(paged,key,tile.data.hash) {continue}
                ai.nav_mesh_remove_tile(&c.mesh,coord)
                ai.nav_mesh_remove_links_of(&c.mesh,generated_owner(coord))
                mark_remove(c,key)
                links_mark(n,i,coord)
                n.stats.dropped+=1
                n.revision+=1
            }
        }
        // Marks with nothing to keep there wait for nothing.
        clear(&gone)
        it:=base.hash_map_iterator(&c.marks)
        for key,mark in base.hash_map_iterate(&it) {
            if !mark.building && boxes_cover(boxes,mark_box_of(c,key,volume),!volume) {append(&gone,key)}
        }
        for key in gone {if paged_put(paged,key,0) {mark_remove(c,key)}}
    }
}

// Reads again the tiles and zones of paged that the boxes no longer cover,
// one read of each bake for all of them, and marks them: the build checks
// them against the collision.
@(private)
paging_restore :: proc(n:^Navigation,b:^Navigation_Builds,boxes:[]mm.Aabb,app:^host.App,problems:^core.Problems) {
    back:[NAV_CLASS_CAPACITY]base.Hash_Map(u64)
    restored:=false
    for i in 0..<n.count {
        paged:=&b.paged[i]
        if paged.count==0 || !base.hash_map_init(&back[i],paged.count,context.temp_allocator) {continue}
        c:=&n.classes[i]
        volume:=class_in_volume(n,i)
        it:=base.hash_map_iterator(paged)
        for key,hash in base.hash_map_iterate(&it) {
            if !boxes_cover(boxes,mark_box_of(c,key,volume),!volume) {base.hash_map_set(&back[i],key,hash^)}
        }
        it=base.hash_map_iterator(&back[i])
        for key in base.hash_map_iterate(&it) {base.hash_map_remove(paged,key)}
        restored||=back[i].count>0
    }
    if !restored {return}
    for id in b.bakes.values {bake_load(n,{asset=id},app,problems,&back)}
    for i in 0..<n.count {
        c:=&n.classes[i]
        volume:=class_in_volume(n,i)
        it:=base.hash_map_iterator(&back[i])
        for key in base.hash_map_iterate(&it) {
            if mark,_:=base.hash_map_insert(&c.marks,key);mark!=nil {mark_set(c,mark,marked(mark^,false))}
            // The links of the neighbours that reach into one that came back are made again.
            if !volume && ai.nav_mesh_tile_at(&c.mesh,coord_of_key(key))!=nil {links_mark(n,i,coord_of_key(key))}
        }
    }
}

// Keeps a tile or zone that went, with the hash of the one it had (0: none,
// which leaves one kept before). False without room.
@(private)
paged_put :: proc(paged:^base.Hash_Map(u64),key,hash:u64) -> bool {
    if paged.count>=paged.capacity && !base.hash_map_contains(paged,key) {
        grown:=base.hash_map_init(paged,64) if paged.capacity==0 else base.hash_map_grow(paged,paged.capacity*2)
        if !grown {return false}
    }
    value,_:=base.hash_map_insert(paged,key)
    if value==nil {return false}
    if hash!=0 {value^=hash}
    return true
}

// Each Navigation_Bake that comes, with the scene or with a section that
// loads, puts in the meshes what its .navmesh has that they do not. adopt:
// the meshes have them already (a copy of the world).
@(private)
bakes_update :: proc(n:^Navigation,b:^Navigation_Builds,bakes:core.Read(Navigation_Bake),app:^host.App,problems:^core.Problems,adopt:bool) {
    seen:=core.version(bakes)+core.layout(bakes)+1
    if seen==b.bakes_seen {return}
    b.bakes_seen=seen
    kept:=make([]bool,len(b.bakes.values),context.temp_allocator)
    for row in 0..<core.count(bakes) {
        e:=core.entity_at(bakes,row)
        bake:=core.at(bakes,row)
        at:=core.entity_map_index(&b.bakes,e)
        if at<0 || b.bakes.values[at]!=bake.asset {
            if !adopt {bake_load(n,bake,app,problems)}
            core.entity_map_put(&b.bakes,e,bake.asset)
            at=core.entity_map_index(&b.bakes,e)
        }
        if at>=0 && at<len(kept) {kept[at]=true}
    }
    for at:=len(kept)-1;at>=0;at-=1 {if !kept[at] {core.entity_map_remove_at(&b.bakes,at)}}
}

// The hash of the tiles of a class over a box, those that went in a run with
// the hash they had, and whether they settled; 0 for a box too big for the
// coarse graph to cross it.
@(private)
region_hash :: proc(c:^Class_Mesh,paged:^base.Hash_Map(u64),box:mm.Aabb) -> (h:u64,settled:bool) {
    low,high:=ai.nav_mesh_coord(&c.mesh,box.min),ai.nav_mesh_coord(&c.mesh,box.max)
    if i64(high.x)-i64(low.x)>4096 || i64(high.y)-i64(low.y)>4096 {return 0,true}
    config:=c.config
    h=base.hash64(mem.ptr_to_bytes(&config))
    for z in low.y-1..=high.y+1 {
        for x in low.x-1..=high.x+1 {
            key:=coord_key({x,z})
            if mark:=base.hash_map_ptr(&c.marks,key);mark!=nil && (mark.dirty && !mark.unloaded || mark.building || mark.links) {return 0,false}
            tile:=ai.nav_mesh_tile_at(&c.mesh,{x,z})
            hash:=tile.data.hash if tile!=nil else base.hash_map_get(paged,key)
            if hash==0 {continue}
            h=base.hash_combine(base.hash_combine(h,key),hash)
        }
    }
    return h,true
}

// The hash of the zones of a class of a volume over a box, those that went in
// a run with the hash they had, and whether they settled; 0 for a box with no
// zone, or too big for the coarse graph to cross it.
@(private)
region_hash_volume :: proc(c:^Class_Mesh,paged:^base.Hash_Map(u64),box:mm.Aabb) -> (h:u64,settled:bool) {
    low,high:=ai.nav_volume_coord(&c.volume,box.min)-1,ai.nav_volume_coord(&c.volume,box.max)+1
    if i64(high.x-low.x+1)*i64(high.y-low.y+1)*i64(high.z-low.z+1)>1<<16 {return 0,true}
    config:=c.volume_config
    h=base.hash64(mem.ptr_to_bytes(&config))
    zones:=0
    for z in low.z..=high.z {
        for y in low.y..=high.y {
            for x in low.x..=high.x {
                key:=zone_key({x,y,z})
                if mark:=base.hash_map_ptr(&c.marks,key);mark!=nil && (mark.dirty && !mark.unloaded || mark.building) {return 0,false}
                zone:=ai.nav_volume_zone_at(&c.volume,{x,y,z})
                hash:=zone.data.hash if zone!=nil else base.hash_map_get(paged,key)
                if hash==0 {continue}
                h=base.hash_combine(base.hash_combine(h,key),hash)
                zones+=1
            }
        }
    }
    return h if zones>0 else 0,true
}

// Makes again the region of the coarse graph of a section here whose tiles
// or zones settled with other hashes than it was made from, one at a time
// and over ticks (the border of a volume a zone a tick, the ways
// NAV_COARSE_EXPANDED nodes a tick), starting again when what it is made from
// or the sections change meanwhile. Only when a tile, a zone or a section
// changed since it last looked, or a region is on its way.
@(private)
coarse_update :: proc(n:^Navigation,b:^Navigation_Builds,problems:^core.Problems) {
    s:=&b.sections
    if n.revision==b.coarse_revision && s.hash==b.coarse_sections && !b.region_busy {return}
    waiting,going:=false,false
    next:struct {class:int,item:int,hash:u64}
    next.class=-1
    // The portals toward a section away stay: its mesh is not there to show them again.
    away:[NAV_SECTIONS_MAX]u64
    away_count:=0
    for item in s.items[:s.count] {
        if item.away {away[away_count]=item.key;away_count+=1}
    }
    for i in 0..<n.count {
        volume:=class_in_volume(n,i)
        c:=&n.classes[i]
        for item,k in s.items[:s.count] {
            if !item.here {continue}
            on_its_way:=b.region_busy && b.region_class==i && b.region.key==item.key
            h:u64
            settled:bool
            if volume {h,settled=region_hash_volume(c,&b.paged[i],item.box)} else {h,settled=region_hash(c,&b.paged[i],item.box)}
            if !settled {waiting=true;going|=on_its_way;continue}
            if h==0 {
                // No free space of the class there: what flies or swims crosses it straight.
                if volume && ai.nav_coarse_remove(&c.coarse,item.key) {n.revision+=1}
                continue
            }
            if region:=ai.nav_coarse_region(&c.coarse,item.key);region!=nil && region.hash==h {continue}
            waiting=true
            if on_its_way && b.region.hash==h {going=true;continue}
            if next.class<0 {next={i,k,h}}
        }
    }
    if !going || b.region_sections!=s.hash {b.region_busy=false}
    if !b.region_busy && next.class>=0 {
        i:=next.class
        c:=&n.classes[i]
        item:=s.items[next.item]
        volume:=class_in_volume(n,i)
        if len(b.query.points)==0 && !ai.nav_query_init(&b.query,1<<15) || volume && len(b.volume_query.points)==0 && !ai.nav_volume_query_init(&b.volume_query,1<<16) {
            core.report(problems,core.NONE,"navigation.memory","No memory to find the ways of the coarse graph")
            return
        }
        ok:bool
        if volume {
            ok=ai.nav_coarse_begin_region_volume(&b.region,&c.coarse,&c.volume,item.key,next.hash,item.box,away[:away_count])
        } else {
            filter:=coarse_filter(n,c)
            ok=ai.nav_coarse_begin_region(&b.region,&c.coarse,&c.mesh,&filter,item.key,next.hash,item.box,sections_region_of,s,away[:away_count])
        }
        if ok {b.region_busy,b.region_class,b.region_sections=true,i,s.hash} else {coarse_no_memory(c,problems)}
    }
    if b.region_busy {
        c:=&n.classes[b.region_class]
        status:ai.Nav_Coarse_Status
        if class_in_volume(n,b.region_class) {
            status=ai.nav_coarse_step_region_volume(&b.region,&c.coarse,&c.volume,&b.volume_query,sections_region_of,s,NAV_COARSE_EXPANDED)
        } else {
            filter:=coarse_filter(n,c)
            status=ai.nav_coarse_step_region(&b.region,&c.coarse,&c.mesh,&b.query,&filter,NAV_COARSE_EXPANDED)
        }
        switch status {
        case .Running:
        case .Done:
            if !b.region.complete {
                core.report(problems,core.NONE,"navigation.coarse","A section crosses its border in more places than the coarse graph keeps (%d portals): agents far from the players take only some of them",ai.NAV_REGION_PORTALS)
            }
            b.region_busy=false
            n.stats.regions+=1
            n.revision+=1
        case .Failed:
            b.region_busy=false
            coarse_no_memory(c,problems)
            n.revision+=1
        }
    }
    if !waiting {b.coarse_revision,b.coarse_sections=n.revision,s.hash}
}

// What an agent of a class of the surface crosses on the way between two portals.
@(private)
coarse_filter :: proc(n:^Navigation,c:^Class_Mesh) -> ai.Nav_Filter {
    class:=c.class
    return filter_make(&n.settings,Nav_Areas(1<<u64(AREA_WATER)),{up=class.jump_up,across=class.jump_across,down=class.drop})
}

@(private)
coarse_no_memory :: proc(c:^Class_Mesh,problems:^core.Problems) {
    core.report(problems,core.NONE,"navigation.coarse","The coarse graph of class %q has no memory for a section: agents far from the players cross it in a straight line",base.text_get(c.class.name[:]))
}
