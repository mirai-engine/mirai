package behavior

import "core:math/linalg"
import "core:slice"
import "mirai:core"
import "mirai:std/ai"
import mm "mirai:std/math"
import "mirai:std/spatial"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

// What agents perceive. A Perceiver sees the Perceivables of the teams it
// notices that are in its cone and that a ray of the physics reaches, and
// hears the noises the game makes within its hearing; it remembers each in
// its Perception, surer the more recently it perceived it, and forgets it
// `forget` seconds after it last did, or at once when it is destroyed. Each
// looks only at those around it, found in a grid over the ground made every
// tick (Sight). The rays of a tick are shared by all perceivers within
// Behavior_Settings.rays, in turns. A perceiver far from the players (nav.Nav_Far), off with its
// rows, perceives when its brain decides (nav.nav_far_decide), without rays:
// the collision where it is is not loaded.

// A side: a perceiver notices the teams of its mask.
@(names="TEAM_")
Team :: distinct u8
TEAM_NEUTRAL :: Team(0)

@(name_bits="Team")
Teams :: distinct u32

@(component,description="Sees, hears and remembers: the Perceivables of the teams it notices in its cone of sight that nothing hides, and the noises within its hearing.")
Perceiver :: struct {
    sight:f32 `mirai:"min=0,unit=m"`,          // how far it sees
    angle:f32 `mirai:"angle,min=0"`,           // half of the cone it sees, from where its body faces
    eyes:f32 `mirai:"unit=m"`,                 // above its origin
    hearing:f32 `mirai:"min=0"`,               // times the loudness of a noise, in metres, that it hears
    forget:f32 `mirai:"min=0,unit=s"`,         // after it stops perceiving something
    notices:Teams,
}
PERCEIVER_DEFAULT :: Perceiver{sight=20,angle=1.0472,eyes=1.6,hearing=1,forget=8,notices=Teams(0xffffffff)}

@(component,description="Can be seen by Perceivers that notice its team, at the height of its point above its origin.")
Perceivable :: struct {
    team:Team,
    point:f32 `mirai:"unit=m"`, // above its origin, where it is looked at
}
PERCEIVABLE_DEFAULT :: Perceivable{point=1}

// What a perceiver remembers. Behavior adds it to every Perceiver and is its only writer.
@(component,description="What the perceiver remembers of what it saw and heard, and how sure it still is.")
Perception :: struct {
    memory:ai.Perception_Memory `mirai:"transient,readonly"`,
}

// The work of perception, of the queries of places and of the influence maps
// in a tick, for all the agents, and where the maps are.
@(storage,setting)
Behavior_Settings :: struct {
    rays:i32 `mirai:"min=0,advanced"`,    // of sight
    queries:i32 `mirai:"min=0,advanced"`, // of places
    influence_cell:f32 `mirai:"min=0,unit=m"`,     // across a cell of the influence maps; 0: no maps
    influence_size:i32 `mirai:"min=0,max=1024"`,   // cells on a side
    influence_center:[3]f32 `mirai:"unit=m"`,      // of the maps; its height is where the ground of a cell is looked for from above
    influence_cells:i32 `mirai:"min=1,advanced"`,  // spread in a tick
    influence_rays:i32 `mirai:"min=0,advanced"`,   // of cover in a tick
    influence_falloff:f32 `mirai:"min=0,max=1"`,   // of an influence, per metre
    influence_blend:f32 `mirai:"min=0,max=1"`,     // of the way to the new value a pass moves a cell
}
BEHAVIOR_SETTINGS_DEFAULT :: Behavior_Settings{
    rays=256,queries=4,
    influence_cell=2,influence_size=128,influence_cells=8192,influence_rays=90,influence_falloff=0.15,influence_blend=0.6,
}

// A noise the game makes: whoever hears within loudness times its hearing perceives its maker there.
Noise :: struct {
    position:[3]f32,
    loudness:f32,      // m it carries for a hearing of 1
    maker:core.Entity, // whom it reveals; none: only the place
}

@(storage,queue)
Noises :: struct {
    using queue:core.Queue(Noise),
}

noise :: proc(noises:^Noises,position:[3]f32,loudness:f32,maker:=core.NONE) {
    core.push(&noises.queue,Noise{position=position,loudness=loudness,maker=maker})
}

Perception_Event_Kind :: enum u8 {Noticed,Forgot}

Perception_Event :: struct {
    kind:Perception_Event_Kind,
    perceiver:core.Entity,
    subject:core.Entity,
    sense:ai.Sense,
    position:[3]f32,
}

@(storage)
Perception_Events :: struct {
    using queue:core.Events(Perception_Event),
}

// Where the turns of sight are.
@(storage)
Perceiving :: struct {
    next:u32,        // the perceiver that looks first in the next tick
    shapes:[2]core.Shape, // the rows of the perceivers and the perceptions when the perceivers last got their Perception
    remembering:u32, // perceivers, on or off, that remember something
}

SIGHT_CELL :: f32(16) // m across a cell of the grid the Perceivables are looked for in

// The Perceivables of a tick by where they stand on the ground, for each
// perceiver to find those around it. Not the state of the world.
@(storage,host,by_world,free="sight_free")
Sight :: struct {
    grid:spatial.Grid,
    rows:[dynamic]u32, // of the Perceivables around a perceiver, in the order of their table
}

sight_free :: proc(s:^Sight) {
    spatial.grid_destroy(&s.grid)
    delete(s.rows)
    s^={}
}

@(step="fixed",stage="input",server)
perception_update :: proc(
    perceivers:core.Read(Perceiver),perceptions:^core.Table(Perception),perceivables:core.Read(Perceivable),
    worlds:core.Read(core.World_Transform),settings:core.Ref(Behavior_Settings),turns:^Perceiving,sight:^Sight,
    noises:^Noises,events:^Perception_Events,physics:core.Ref(phys.Physics_State),fars:core.Read(nav.Nav_Far),entities:core.Ref(core.Entities),time:core.Time,problems:^core.Problems,
) {
    if core.reshaped(perceivers,&turns.shapes[0]) | core.reshaped(perceptions,&turns.shapes[1]) {
        for row in 0..<core.count(perceivers) {
            e:=core.entity_at(perceivers,row)
            if !core.has(perceptions,e) {core.add(perceptions,e,Perception{})}
        }
        turns.remembering=0
        for &mine in perceptions.values {
            if mine.memory.count>0 {turns.remembering+=1}
        }
    }
    heard:=core.take(&noises.queue)
    if !time.playing || time.dt<=0 {return}
    // With nobody to look at or to hear, and nothing remembered, nobody perceives or forgets.
    if len(perceivers.table.entities)==0 || len(perceivables.table.entities)==0 && len(heard)==0 && turns.remembering==0 {return}
    count:=core.count(perceivers)
    rays:=int(settings.rays) if settings.ptr!=nil else 256
    far:=nav.nav_far_decide(time) && fars.table!=nil && len(perceivers.table.entities)>count
    // Without rays nobody looks, and all remember as time goes.
    sighted:=rays>0
    if (far || sighted && count>0) && !sight_gather(sight,perceivables,worlds,fars,far) {
        core.report(problems,core.NONE,"behavior.memory","No memory to look for the %d Perceivables around each perceiver: nobody sees in this tick; free memory",len(perceivables.table.entities))
        sighted,rays,far=false,0,false
    }
    if far {perceive_far(perceivers,perceptions,perceivables,worlds,fars,sight,heard,events,turns,entities.ptr,time)}
    if count==0 {return}
    first:=int(turns.next)%count
    for k in 0..<count {
        row:=(first+k)%count
        e:=core.entity_at(perceivers,row)
        p:=perceivers.table.values[row]
        mine:=core.edit(perceptions,e)
        pose,placed:=core.get(worlds,e)
        if mine==nil || !placed {continue}
        remembered:=mine.memory.count>0
        // Only those whose turn came look and forget: the others keep what they could not look at.
        turn:=rays>0 || !sighted
        eye:=pose.position+mm.Vec3{0,p.eyes,0}
        forward:=mm.quat_forward(pose.rotation)
        if rays>0 {
            for target in sight_around(sight,eye,p.sight,core.count(perceivables)) {
                if rays<=0 {break}
                subject:=core.entity_at(perceivables,int(target))
                if subject==e {continue}
                seen:=perceivables.table.values[target]
                if u32(p.notices)&(1<<u32(seen.team))==0 {continue}
                at,ok:=core.get(worlds,subject)
                if !ok {continue}
                point:=at.position+mm.Vec3{0,seen.point,0}
                if !ai.sight_in_cone(eye,forward,point,p.sight,p.angle) {continue}
                rays-=1
                to:=point-eye
                distance:=linalg.length(to)
                if distance>1e-4 {
                    if hit,blocked:=phys.raycast(physics,eye,to/distance,distance,e);blocked && hit.entity!=subject {continue}
                }
                if ai.memory_perceive(&mine.memory,u64(subject),at.position,.Sight,1,time.tick)==.New {
                    core.push(&events.queue,Perception_Event{kind=.Noticed,perceiver=e,subject=subject,sense=.Sight,position=at.position})
                }
            }
        }
        if turn && sighted && rays<=0 && k+1<count {turns.next=u32((row+1)%count)}
        hear(&mine.memory,e,p,pose.position,heard,events,time)
        if turn {forget(&mine.memory,e,p,events,entities.ptr,time)}
        remembering_count(turns,remembered,mine.memory.count>0)
    }
}

@(private)
remembering_count :: #force_inline proc "contextless" (turns:^Perceiving,before,after:bool) {
    if after && !before {turns.remembering+=1}
    if before && !after && turns.remembering>0 {turns.remembering-=1}
}

// Puts the Perceivables that are on, and with `far` those that are far
// (nav.Nav_Far) too, in the grid by where they stand, each with its row.
// False without memory for them.
@(private)
sight_gather :: proc(s:^Sight,perceivables:core.Read(Perceivable),worlds:core.Read(core.World_Transform),fars:core.Read(nav.Nav_Far),far:bool) -> bool {
    on:=core.count(perceivables)
    rows:=len(perceivables.table.entities) if far else on
    if rows>len(s.grid.items) {
        capacity:=64
        for capacity<rows {capacity*=2}
        spatial.grid_destroy(&s.grid)
        if !spatial.grid_init(&s.grid,{cell_size=SIGHT_CELL,buckets=capacity*2,item_capacity=capacity}) {return false}
    }
    spatial.grid_clear(&s.grid)
    for row in 0..<rows {
        e:=perceivables.table.entities[row]
        if row>=on && !far_of(fars,e) {continue}
        at,ok:=core.get(worlds,e)
        if !ok {continue}
        spatial.grid_insert(&s.grid,sight_box(at.position,0),u64(row))
    }
    return true
}

// The box of the grid around a point on the ground: all its cells are of one height.
@(private)
sight_box :: #force_inline proc "contextless" (at:mm.Vec3,reach:f32) -> mm.Aabb {
    return {{at.x-reach,SIGHT_CELL*0.5,at.z-reach},{at.x+reach,SIGHT_CELL*0.5,at.z+reach}}
}

// The rows below `limit` of the Perceivables that stand within `reach` of
// the eye over the ground, and some beyond, in the order of their table:
// the turns of the rays and what a full memory keeps follow that order.
@(private)
sight_around :: proc(s:^Sight,eye:mm.Vec3,reach:f32,limit:int) -> []u32 {
    clear(&s.rows)
    query:=spatial.grid_query(&s.grid,sight_box(eye,abs(reach)))
    for {
        _,row,ok:=spatial.grid_query_next(&query)
        if !ok {break}
        if int(row)<limit && append(&s.rows,u32(row))==0 {break}
    }
    slice.sort(s.rows[:])
    return s.rows[:]
}

@(private)
far_of :: proc(fars:core.Read(nav.Nav_Far),e:core.Entity) -> bool {return core.raw_find(core.raw(fars.table),type_info_of(nav.Nav_Far),e)!=nil}

// What the perceivers far from the players perceive, at the ticks their
// brains decide in: what they notice in their cone and range, on or far
// itself, as if nothing hid it (the collision there is not loaded), and the
// noises of the tick; then they forget.
@(private)
perceive_far :: proc(perceivers:core.Read(Perceiver),perceptions:^core.Table(Perception),perceivables:core.Read(Perceivable),worlds:core.Read(core.World_Transform),fars:core.Read(nav.Nav_Far),sight:^Sight,heard:[]Noise,events:^Perception_Events,turns:^Perceiving,entities:^core.Entities,time:core.Time) {
    for row in core.count(perceivers)..<len(perceivers.table.entities) {
        e:=perceivers.table.entities[row]
        if !far_of(fars,e) {continue}
        p:=perceivers.table.values[row]
        mine:=cast(^Perception)core.raw_edit(core.raw(perceptions),type_info_of(Perception),e)
        pose,placed:=core.get(worlds,e)
        if mine==nil || !placed {continue}
        remembered:=mine.memory.count>0
        eye:=pose.position+mm.Vec3{0,p.eyes,0}
        forward:=mm.quat_forward(pose.rotation)
        for target in sight_around(sight,eye,p.sight,len(perceivables.table.entities)) {
            subject:=perceivables.table.entities[target]
            if subject==e {continue}
            seen:=perceivables.table.values[target]
            if u32(p.notices)&(1<<u32(seen.team))==0 {continue}
            at,ok:=core.get(worlds,subject)
            if !ok || !ai.sight_in_cone(eye,forward,at.position+mm.Vec3{0,seen.point,0},p.sight,p.angle) {continue}
            if ai.memory_perceive(&mine.memory,u64(subject),at.position,.Sight,1,time.tick)==.New {
                core.push(&events.queue,Perception_Event{kind=.Noticed,perceiver=e,subject=subject,sense=.Sight,position=at.position})
            }
        }
        hear(&mine.memory,e,p,pose.position,heard,events,time)
        forget(&mine.memory,e,p,events,entities,time)
        remembering_count(turns,remembered,mine.memory.count>0)
    }
}

@(private)
hear :: proc(memory:^ai.Perception_Memory,e:core.Entity,p:Perceiver,position:mm.Vec3,heard:[]Noise,events:^Perception_Events,time:core.Time) {
    for n in heard {
        if !(n.loudness>0) || linalg.length(mm.Vec3(n.position)-position)>n.loudness*p.hearing {continue}
        if ai.memory_perceive(memory,u64(n.maker),n.position,.Hearing,0.75,time.tick)==.New {
            core.push(&events.queue,Perception_Event{kind=.Noticed,perceiver=e,subject=n.maker,sense=.Hearing,position=n.position})
        }
    }
}

// Forgets at once what was destroyed (its handle names nothing), and the
// rest `forget` seconds after it was last perceived.
@(private)
forget :: proc(memory:^ai.Perception_Memory,e:core.Entity,p:Perceiver,events:^Perception_Events,entities:^core.Entities,time:core.Time) {
    gone:[ai.PERCEPTION_CAPACITY]u64
    dead:=0
    for o in memory.items[:clamp(memory.count,0,ai.PERCEPTION_CAPACITY)] {
        if o.subject!=0 && !core.alive(entities,core.Entity(o.subject)) {gone[dead]=o.subject;dead+=1}
    }
    for subject in gone[:dead] {
        ai.memory_remove(memory,subject)
        core.push(&events.queue,Perception_Event{kind=.Forgot,perceiver=e,subject=core.Entity(subject)})
    }
    forgotten:=ai.memory_forget(memory,time.tick,time.dt,p.forget,gone[:])
    for subject in gone[:min(forgotten,len(gone))] {
        core.push(&events.queue,Perception_Event{kind=.Forgot,perceiver=e,subject=core.Entity(subject)})
    }
}
