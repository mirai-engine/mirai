package scene

import "core:math"
import "core:math/linalg"
import "core:slice"
import "mirai:core"
import input "mirai:engine/input"
import mm "mirai:std/math"

// Where the world streams around, and the one residency by distance that the
// plugin streaming (sections), the terrain (chunks) and the foliage (cells)
// use: the view while it draws, the body each seat drives (on a server, those
// of every connection) and each entity with a Streaming_Source are sources,
// each also where its motion takes it in SOURCE_PREFETCH seconds (the view,
// where it went since the frame before, unless it jumped: View.cut). What
// comes within reach of a source is resident, and goes once every source is
// RESIDENT_KEEP times its reach away; past a budget, the nearest stay.
//
// The simulation does not read those: what decides by distance (minds,
// avoidance, the order of the navmesh builds) reads Simulation_Sources, the
// bodies and the marks of the tick without the view, so a world decides the
// same whoever looks at it and at whatever frame rate.

SOURCES_MAX :: 64
SOURCE_PREFETCH :: 1 // s
SOURCE_MOVE :: f32(0.25) // m a source moves before the residencies look again
RESIDENT_KEEP :: f32(1.25) // what is resident goes once every source is this many times its reach away: one at the border does not come and go

@(component,description="An entity around which sections, terrain chunks and foliage stay loaded and the agents decide as near: a camera, the place a teleport goes to. The view and the bodies the players drive are sources already.")
Streaming_Source :: struct {
    distance:f32 `mirai:"min=0,unit=m"`, // what stays loaded around it; 0: what each library keeps around the view
}

Source :: struct {
    position,ahead:[3]f32, // where it is, and where its motion takes it
    distance:f32,          // 0: what each library keeps around the view
}

@(storage)
Streaming_Sources :: struct {
    items:[SOURCES_MAX]Source,
    count:int,
    revision:u64, // grows when a source comes, goes or moves SOURCE_MOVE
    view:[3]f32,  // where the view was in the frame before
    viewed:bool,  // there was a view in the frame before
}

// The sources of the tick for what the simulation decides by distance: the
// bodies the seats drive and the Streaming_Source entities, never the view.
@(storage)
Simulation_Sources :: struct {
    items:[SOURCES_MAX]Source,
    count:int,
}

@(step="frame",loops="game editor",before="scene_sections")
scene_sources :: proc(
    sources:^Streaming_Sources,view:core.View,frame:core.Frame_Time,seats:^core.Table(input.Seat,.Read),
    marks:^core.Table(Streaming_Source,.Read),worlds:^core.Table(core.World_Transform,.Read),motions:^core.Table(core.Motion,.Read),problems:^core.Problems,
) {
    list:[SOURCES_MAX]Source
    count:=0
    if view.size.x>0 && view.size.y>0 {
        ahead:=view.position
        if sources.viewed && !view.cut && frame.dt>0 {ahead+=(view.position-sources.view)/frame.dt*SOURCE_PREFETCH}
        list[0]={view.position,ahead,0}
        count=1
    }
    sources.view,sources.viewed=view.position,view.size.x>0 && view.size.y>0
    count=sources_gather(&list,count,seats,marks,worlds,motions,problems)
    // What moved less than SOURCE_MOVE is where it was: the residencies look again when something moved.
    if !sources_moved(sources.items[:sources.count],list[:count]) {return}
    sources.items=list
    sources.count=count
    sources.revision+=1
}

@(step="fixed",loops="game editor",stage="input")
scene_simulation_sources :: proc(
    sources:^Simulation_Sources,seats:^core.Table(input.Seat,.Read),marks:^core.Table(Streaming_Source,.Read),
    worlds:^core.Table(core.World_Transform,.Read),motions:^core.Table(core.Motion,.Read),problems:^core.Problems,
) {
    sources.count=sources_gather(&sources.items,0,seats,marks,worlds,motions,problems)
}

// Whether sources are others than those of before: one came or went, or
// moved SOURCE_MOVE or more.
sources_moved :: proc "contextless" (before,now:[]Source) -> bool {
    if len(before)!=len(now) {return true}
    for source,i in now {
        was:=before[i]
        if source.distance!=was.distance || linalg.length2(source.position-was.position)>SOURCE_MOVE*SOURCE_MOVE || linalg.length2(source.ahead-was.ahead)>SOURCE_MOVE*SOURCE_MOVE {return true}
    }
    return false
}

// Adds to list, from count, the bodies the seats drive and the marks, each
// where it is and where its motion takes it; the new count.
@(private)
sources_gather :: proc(
    list:^[SOURCES_MAX]Source,count:int,seats:^core.Table(input.Seat,$A),marks:^core.Table(Streaming_Source,$B),
    worlds:^core.Table(core.World_Transform,$C),motions:^core.Table(core.Motion,$D),problems:^core.Problems,
) -> int {
    count,wanted:=count,count
    add :: proc(list:^[SOURCES_MAX]Source,count,wanted:^int,worlds:^core.Table(core.World_Transform,$A),motions:^core.Table(core.Motion,$B),e:core.Entity,distance:f32) {
        at,placed:=core.get(worlds,e)
        if !placed {return}
        wanted^+=1
        if count^==SOURCES_MAX {return}
        motion,_:=core.get(motions,e)
        list[count^]={at.position,at.position+motion.linear*SOURCE_PREFETCH,distance}
        count^+=1
    }
    for row in 0..<core.count(seats) {add(list,&count,&wanted,worlds,motions,core.at(seats,row).body,0)}
    for row in 0..<core.count(marks) {add(list,&count,&wanted,worlds,motions,core.entity_at(marks,row),core.at(marks,row).distance)}
    if wanted>SOURCES_MAX {
        core.report(problems,core.NONE,"scene.sources","%d streaming sources and SOURCES_MAX is %d: those past it load nothing around them; take Streaming_Source from the entities that do not need it",wanted,SOURCES_MAX)
    }
    return count
}

// m from a box (a point: low==high) to the nearest simulation source, past
// what that source keeps around it (Source.distance): 0 within it, and 0
// without sources, as all is near then. A point that is not a number is
// infinitely far.
sources_distance :: proc "contextless" (sources:^Simulation_Sources,low,high:[3]f32) -> f32 {
    if sources==nil || sources.count<=0 {return 0}
    if low!=low || high!=high {return math.INF_F32}
    nearest:=math.INF_F32
    for source in sources.items[:clamp(sources.count,0,SOURCES_MAX)] {
        keeps:=source.distance if source.distance>0 && source.distance<=max(f32) else 0
        if d:=box_distance(low,high,source.position)-keeps;d<nearest {nearest=d}
    }
    return max(nearest,0)
}

// The sources as something placed by a matrix sees them: each, and where it
// goes, in its frame, with how far it reaches there. reach: that of a source
// without a distance of its own; one that reaches nothing is left out.
Sources_Near :: struct {
    points:[2*SOURCES_MAX][3]f32,
    reaches:[2*SOURCES_MAX]f32,
    count:int,
}

sources_near :: proc "contextless" (sources:^Streaming_Sources,placed:mm.Mat4,reach:f32) -> Sources_Near {
    if sources==nil {return {}}
    return sources_near_of(sources.items[:clamp(sources.count,0,SOURCES_MAX)],placed,reach)
}

// The same of a list of sources, as those of the simulation.
sources_near_of :: proc "contextless" (sources:[]Source,placed:mm.Mat4,reach:f32) -> (near:Sources_Near) {
    if len(sources)==0 {return}
    inverse:=linalg.inverse(placed)
    scale:=max(linalg.length(placed[0].xyz),linalg.length(placed[1].xyz),linalg.length(placed[2].xyz))
    if !(scale>0) {return}
    for source in sources[:min(len(sources),SOURCES_MAX)] {
        distance:=source.distance>0?source.distance:reach
        if !(distance>0 && distance-distance==0) {continue}
        for point,i in ([2][3]f32{source.position,source.ahead}) {
            if i==1 && point==source.position {continue}
            near.points[near.count]=(inverse*[4]f32{point.x,point.y,point.z,1}).xyz
            near.reaches[near.count]=distance/scale
            near.count+=1
        }
    }
    return
}

// How near the sources come to a box of their frame, in reaches: 0 inside, 1
// at the reach of one; max(f32) without sources.
box_near :: proc "contextless" (near:^Sources_Near,low,high:[3]f32) -> f32 {
    nearest:=max(f32)
    for point,i in near.points[:near.count] {nearest=min(nearest,box_distance(low,high,point)/near.reaches[i])}
    return nearest
}

// Whether something that was resident, or not, is at near (box_near).
resident :: #force_inline proc "contextless" (near:f32,was:bool) -> bool {return near<=1 || was && near<=RESIDENT_KEEP}

box_distance :: #force_inline proc "contextless" (low,high,p:[3]f32) -> f32 {
    outside:=[3]f32{max(low.x-p.x,0,p.x-high.x),max(low.y-p.y,0,p.y-high.y),max(low.z-p.z,0,p.z-high.z)}
    return linalg.length(outside)
}

// Something resident at near, by its index where it is kept.
Resident_Order :: struct {
    near:f32,
    index:u32,
}

// The budget of what is resident: the nearest keep stay, in order, and the
// rest, which goes, is returned.
residents_past :: proc(order:[]Resident_Order,keep:int) -> []Resident_Order {
    slice.sort_by(order,proc(a,b:Resident_Order) -> bool {return a.near<b.near || a.near==b.near && a.index<b.index})
    return order[clamp(keep,0,len(order)):]
}
