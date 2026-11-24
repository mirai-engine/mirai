package navigation

import "core:mem"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"

// The sections of the world that have a box, as navigation sees them. One is
// here while it is loaded and on. One that is not is away, unless the box of
// one here holds its own (two versions of the same place, a section inside
// another): where only away sections are, their tiles go and an agent with
// somewhere to go goes on far from the players. The region of a point, for
// the coarse graph, is the Id of the reference of the smallest box that holds
// it; 0 outside every box.

NAV_COVER_STEPS :: 4096 // pieces a box is cut into to find whether away boxes cover it; past them it is not covered

Nav_Section :: struct {
    box:mm.Aabb,
    key:u64,
    here,away:bool,
}

// Gathered again, in what it holds already, when the sections change: it
// grows with them and allocates only then.
Nav_Sections :: struct {
    items:[dynamic]Nav_Section,
    away:[dynamic]mm.Aabb, // the boxes of those away
    away_keys:[dynamic]u64,
    here:[dynamic]mm.Aabb, // the boxes of those here
    hash:u64, // changes when a box, a key or a state does
}

sections_free :: proc(s:^Nav_Sections) {
    delete(s.items);delete(s.away);delete(s.away_keys);delete(s.here)
    s^={}
}

// The region key of a reference: its Id, or its handle with the top bit when it has none.
section_key :: proc "contextless" (ids:^core.Table(core.Id,$A),e:core.Entity) -> u64 {
    if id,ok:=core.get(ids,e);ok && id.value!=0 {return u64(id.value)&~(u64(1)<<63)}
    return u64(e)|u64(1)<<63
}

// Gathers the sections with a box into s. Without memory for all of them,
// those past what it holds are not seen, and without memory for those away
// none is away (their tiles build from what is here): a problem says so, and false.
sections_gather :: proc(s:^Nav_Sections,references:^core.Table(scene.Scene_Reference,$A),worlds:^core.Table(core.World_Transform,$B),ids:^core.Table(core.Id,$C),problems:^core.Problems) -> bool {
    clear(&s.items);clear(&s.away);clear(&s.away_keys);clear(&s.here)
    first:=core.NONE
    dropped:=0
    for row in 0..<core.count(references) {
        reference:=core.at(references,row)
        e:=core.entity_at(references,row)
        pose,placed:=core.get(worlds,e)
        if !placed {continue}
        box:=scene.section_bounds(reference,pose.transform)
        if mm.aabb_is_empty(box) {continue}
        if dropped==0 {
            item:=Nav_Section{box=box,key=section_key(ids,e),here=reference.loaded!={} && scene.section_state(reference)==.Active}
            _,error:=append(&s.items,item)
            if error==nil && item.here {
                if _,error=append(&s.here,box);error!=nil {pop(&s.items)}
            }
            if error==nil {continue}
            first=e
        }
        dropped+=1
    }
    if dropped>0 {
        core.report(problems,first,"navigation.memory","No memory for %d sections with a box, from this one (key %x) on: their tiles do not wait for them. Free memory",dropped,section_key(ids,first))
    }
    roomy:=reserve(&s.away,len(s.items))==nil && reserve(&s.away_keys,len(s.items))==nil
    if !roomy {core.report(problems,core.NONE,"navigation.memory","No memory for the sections that are not loaded: their tiles build from what is here. Free memory")}
    h:=u64(len(s.items))
    for &item in s.items {
        if !item.here && roomy {
            held:=false
            for here in s.here {if mm.aabb_contains(here,item.box) {held=true;break}}
            item.away=!held
            if item.away {append(&s.away,item.box);append(&s.away_keys,item.key)}
        }
        h=base.hash64(mem.ptr_to_bytes(&item.box),h)
        h=base.hash_combine(h,item.key)
        h=base.hash_combine(h,u64(item.here)|u64(item.away)<<1)
    }
    s.hash=h
    return dropped==0 && roomy
}

// Whether a point is where only away sections are: in an away box and in no box here.
sections_away :: proc "contextless" (s:^Nav_Sections,point:mm.Vec3) -> bool {
    away:=false
    for item in s.items {
        if !mm.aabb_contains_point(item.box,point) {continue}
        if item.here {return false}
        away||=item.away
    }
    return away
}

// The region of a point: the key of the smallest box that holds it (one here
// before one that is not), 0 outside every box.
sections_region :: proc "contextless" (s:^Nav_Sections,point:mm.Vec3) -> u64 {
    key:u64
    best:=f32(max(f32))
    here:=false
    for item in s.items {
        if !mm.aabb_contains_point(item.box,point) {continue}
        volume:=mm.aabb_volume(item.box)
        if volume<best || volume==best && item.here && !here {key,best,here=item.key,volume,item.here}
    }
    return key
}

// Whether a box lies where only away sections are: inside the away boxes
// together and outside every box here; flat, seen from above.
sections_covered :: proc "contextless" (s:^Nav_Sections,box:mm.Aabb,flat:=false) -> bool {
    if len(s.away)==0 || mm.aabb_is_empty(box) {return false}
    target:=level(box,flat)
    for here in s.here {if mm.aabb_overlaps(level(here,flat),target) {return false}}
    return boxes_cover(s.away[:],box,flat)
}

// Whether, seen from above, the sections here cover a box: what lies there
// and is not here is above or below them, in their column.
sections_stacked :: proc "contextless" (s:^Nav_Sections,box:mm.Aabb) -> bool {
    return boxes_cover(s.here[:],box,true)
}

// Whether the boxes together cover a box; flat, seen from above.
boxes_cover :: proc "contextless" (boxes:[]mm.Aabb,box:mm.Aabb,flat:=false) -> bool {
    if len(boxes)==0 || mm.aabb_is_empty(box) {return false}
    steps:=NAV_COVER_STEPS
    return covered(level(box,flat),boxes,flat,&steps)
}

@(private="file")
level :: #force_inline proc "contextless" (box:mm.Aabb,flat:bool) -> mm.Aabb {return {{box.min.x,0,box.min.z},{box.max.x,0,box.max.z}} if flat else box}

// Whether the boxes, leveled when flat, cover a box: what the first one it
// touches leaves out of it, cut in up to six boxes, must be covered by the rest.
@(private="file")
covered :: proc "contextless" (box:mm.Aabb,boxes:[]mm.Aabb,flat:bool,steps:^int) -> bool {
    steps^-=1
    if steps^<0 {return false}
    for unleveled,i in boxes {
        b:=level(unleveled,flat)
        if !mm.aabb_overlaps(b,box) {continue}
        if mm.aabb_contains(b,box) {return true}
        rest:=boxes[i+1:]
        left:=box
        for axis in 0..<3 {
            if left.min[axis]<b.min[axis] {
                piece:=left
                piece.max[axis]=b.min[axis]
                if !covered(piece,rest,flat,steps) {return false}
                left.min[axis]=b.min[axis]
            }
            if left.max[axis]>b.max[axis] {
                piece:=left
                piece.min[axis]=b.max[axis]
                if !covered(piece,rest,flat,steps) {return false}
                left.max[axis]=b.max[axis]
            }
        }
        return true
    }
    return false
}

// The region of a point of the surface for the coarse graph: user is a ^Nav_Sections.
@(private)
sections_region_of :: proc(user:rawptr,point:mm.Vec3) -> u64 {return sections_region(cast(^Nav_Sections)user,point)}
