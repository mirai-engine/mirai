package streaming

import "core:math/linalg"
import "mirai:core"
import scene "mirai:engine/scene"
import mm "mirai:std/math"

// The sections whose rule is Spatial load by where the players of this end
// are, with the residency of the sources (scene.resident): a section loads off
// once a source, or where its motion takes it, comes within load of its box
// (or the distance of the source), turns on within active, and turns off or
// drops once every source is scene.RESIDENT_KEEP times either away. Each end
// streams its own: the state of a Spatial section does not travel. Only what
// moved is looked at again: all of them when the sources moved, one whose
// box moved otherwise.

@(storage,setting)
Streaming_Settings :: struct {
    active:f32 `mirai:"min=0,unit=m"`, // a section turns on when a source comes this near its box
    load:f32 `mirai:"min=0,unit=m"`,   // and loads, off, this near
}

STREAMING_SETTINGS_DEFAULT :: Streaming_Settings{active=40,load=80}

// What streaming_sections last looked at.
@(storage)
Streaming_Seen :: struct {
    sources:u64,    // Streaming_Sources.revision
    references:core.Seen, // the table of Scene_Reference
    worlds:core.Seen,
    settings:Streaming_Settings,
}

// How far a point is from the box of a section: 0 inside.
section_distance :: proc "contextless" (reference:scene.Scene_Reference,pose:mm.Transform,point:[3]f32) -> f32 {
    local:=mm.quat_rotate(mm.quat_inverse(pose.rotation),point-pose.position)
    half:=reference.extents*linalg.abs(pose.scale)
    outside:=linalg.max(linalg.abs(local)-half,[3]f32{})
    return linalg.length(outside)
}

@(step="frame",loops="game editor",before="scene_sections")
streaming_sections :: proc(sources:core.Ref(scene.Streaming_Sources),references:core.Read(scene.Scene_Reference),worlds:core.Read(core.World_Transform),settings:core.Ref(Streaming_Settings),seen:^Streaming_Seen,requests:^scene.Section_Requests) {
    s:=settings.ptr!=nil?settings.ptr^:STREAMING_SETTINGS_DEFAULT
    if sources.ptr==nil || s.load<=0 {return}
    moved:=core.changes(worlds,&seen.worlds)
    all:=core.touched(references,&seen.references)
    all||=moved.all || sources.ptr.revision!=seen.sources || s!=seen.settings
    if !all && !moved.written {return}
    seen.sources,seen.settings=sources.ptr.revision,s
    for row in 0..<core.count(references) {
        reference:=core.at(references,row)
        if reference.rule!=.Spatial {continue}
        e:=core.entity_at(references,row)
        at:=core.row_of(worlds,e)
        if at<0 || !all && !core.changed(worlds,moved,at) {continue}
        pose:=core.at(worlds,at).transform
        // How near the sources come to its box, in loads.
        near:=scene.sources_near(sources.ptr,mm.transform_matrix({pose.position,pose.rotation,{1,1,1}}),s.load)
        half:=reference.extents*linalg.abs(pose.scale)
        nearest:=scene.box_near(&near,-half,half)
        want:=scene.Section_State.Unloaded
        switch {
        case s.active>0 && scene.resident(nearest*s.load/s.active,reference.streamed==.Active): want=.Active
        case scene.resident(nearest,reference.streamed!=.Unloaded):                             want=.Loaded
        }
        if want!=reference.streamed {scene.section_stream(requests,e,want)}
    }
}

// Where each entity that moves was last found to hang, and what it looked at.
@(storage)
Streaming_Crossings :: struct {
    homes:[dynamic]Home, // by entity index
    hierarchy:u64,       // the version of the hierarchy the homes are of
    references:core.Seen, // the table of Scene_Reference it looked at
    worlds:core.Seen,
}

// The section an entity hangs in, unless it moves with something that moves.
Home :: struct {entity,section:core.Entity}

// What moves out of the box of its section (a crate, a vehicle, an NPC) hangs
// from the section on whose box holds it, or from the root, where it is:
// dropping a section does not take what already left it. It stops being of
// the scene it came from, which leaves a tombstone of it when it is dropped.
// What roams (scene.Roaming) and hangs from the root, on or off, hangs again
// from a section that is loaded and on where it is. Only what moved, or what
// a section that changed may hold, is looked at, and where each hangs is
// looked up again only when the hierarchy changed.
@(step="frame",loops="game",before="streaming_sections")
streaming_crossings :: proc(
    motions:core.Read(core.Motion),references:core.Read(scene.Scene_Reference),worlds:core.Read(core.World_Transform),roaming:core.Read(scene.Roaming),
    hierarchy:core.Ref(core.Hierarchy),parents:^core.Table(core.Parent),transforms:^core.Table(core.Transform),members:^core.Table(scene.Section_Member),
    crossings:^Streaming_Crossings,problems:^core.Problems,
) {
    if hierarchy.ptr.version!=crossings.hierarchy {
        clear(&crossings.homes)
        crossings.hierarchy=hierarchy.ptr.version
    }
    moved:=core.changes(worlds,&crossings.worlds)
    sections:=core.touched(references,&crossings.references)
    if !moved.written && !sections {return}
    for row in 0..<core.count(motions) {
        if !core.at(motions,row).awake {continue}
        e:=core.entity_at(motions,row)
        at:=core.row_of(worlds,e)
        if at<0 || !core.changed(worlds,moved,at) {continue}
        index:=core.entity_index(e)
        if index>=len(crossings.homes) && resize(&crossings.homes,index+1)!=nil {
            core.report(problems,e,"streaming.memory","out of memory to follow what moves between sections; this entity stays in the section it hangs from: free memory")
            continue
        }
        if crossings.homes[index].entity!=e {
            section:=core.NONE
            for up:=core.parent_of(hierarchy,e);up!=core.NONE;up=core.parent_of(hierarchy,up) {
                if core.has(references,up) {section=up;break}
                if core.has(motions,up) {break}
            }
            crossings.homes[index]={e,section}
        }
        section:=crossings.homes[index].section
        if section==core.NONE {continue}
        reference,_:=core.get(references,section)
        home,placed:=core.get(worlds,section)
        if !placed || reference.extents=={} || section_distance(reference,home.transform,core.at(worlds,at).position)==0 {continue}
        if !crossing_hang(references,worlds,hierarchy,parents,transforms,e,at,section) {continue}
        core.remove(members,e)
        crossings.homes[index]={}
    }
    // What roams from the root, its rows on or off.
    t:=core.raw(roaming.table)
    for row in 0..<core.raw_count(t) {
        e:=t.entities[row]
        at:=core.row_of(worlds,e)
        if at<0 || core.raw_row(core.raw(parents),e)>=0 || !sections && !core.changed(worlds,moved,at) {continue}
        crossing_hang(references,worlds,hierarchy,parents,transforms,e,at,core.NONE,false)
    }
}

// Hangs e, where it is (its row at of worlds), from the section but from that
// is loaded and on and whose box holds it; when none does, from the root, or,
// with root false, it stays where it hangs.
@(private)
crossing_hang :: proc(references:core.Read(scene.Scene_Reference),worlds:core.Read(core.World_Transform),hierarchy:core.Ref(core.Hierarchy),parents:^core.Table(core.Parent),transforms:^core.Table(core.Transform),e:core.Entity,at:int,from:core.Entity,root:=true) -> (hung:bool) {
    position:=core.at(worlds,at).position
    target:=core.NONE
    target_pose:=mm.TRANSFORM_IDENTITY
    for r in 0..<core.count(references) {
        other,candidate:=core.at(references,r),core.entity_at(references,r)
        pose,ok:=core.get(worlds,candidate)
        if candidate==from || !ok || other.loaded=={} || scene.section_state(other)!=.Active || other.extents=={} {continue}
        if section_distance(other,pose.transform,position)==0 {target,target_pose=candidate,pose.transform;break}
    }
    if target==core.NONE && !root {return false}
    local,ok:=mm.transform_relative(core.at(worlds,at).transform,target_pose)
    if !ok {return false}
    if transform:=(^core.Transform)(core.raw_edit(core.raw(transforms),type_info_of(core.Transform),e));transform!=nil {transform^=transmute(core.Transform)local}
    if target==core.NONE {
        core.remove(parents,e)
        return true
    }
    last:i32=-1
    for child:=core.first_child(hierarchy,target);child!=core.NONE;child=core.next_sibling(hierarchy,child) {
        if p,has:=core.get(parents,child);has {last=max(last,p.order)}
    }
    core.add(parents,e,core.Parent{target,last+1})
    return true
}
