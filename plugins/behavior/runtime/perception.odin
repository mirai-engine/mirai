package behavior

import "core:math/linalg"
import "mirai:core"
import "mirai:std/ai"
import mm "mirai:std/math"
import nav "plugins:navigation/runtime"
import phys "plugins:physics/runtime"

// What agents perceive. A Perceiver sees the Perceivables of the teams it
// notices that are in its cone and that a ray of the physics reaches, and
// hears the noises the game makes within its hearing; it remembers each in
// its Perception, surer the more recently it perceived it, and forgets it
// `forget` seconds after it last did, or at once when it is destroyed. The
// rays of a tick are shared by all perceivers within Behavior_Settings.rays,
// in turns. A perceiver far from the players (nav.Nav_Far), off with its
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

@(storage,events)
Perception_Events :: struct {
    using queue:core.Queue(Perception_Event),
}

// Where the turns of sight are.
@(storage)
Perceiving :: struct {
    next:u32,       // the perceiver that looks first in the next tick
    shapes:[2]core.Shape, // the rows of the perceivers and the perceptions when the perceivers last got their Perception
}

@(step="fixed",stage="input",server)
perception_update :: proc(
    perceivers:core.Read(Perceiver),perceptions:^core.Table(Perception),perceivables:core.Read(Perceivable),
    worlds:core.Read(core.World_Transform),settings:core.Ref(Behavior_Settings),turns:^Perceiving,
    noises:^Noises,events:^Perception_Events,physics:core.Ref(phys.Physics_State),fars:core.Read(nav.Nav_Far),entities:core.Ref(core.Entities),time:core.Time,
) {
    core.queue_clear(&events.queue)
    if core.reshaped(perceivers,&turns.shapes[0]) | core.reshaped(perceptions,&turns.shapes[1]) {
        for row in 0..<core.count(perceivers) {
            e:=core.entity_at(perceivers,row)
            if !core.has(perceptions,e) {core.add(perceptions,e,Perception{})}
        }
    }
    heard:=core.take(&noises.queue)
    if !time.playing || time.dt<=0 {return}
    now:=time.seconds
    if nav.nav_far_decide(time) {perceive_far(perceivers,perceptions,perceivables,worlds,fars,heard,events,entities.ptr,now)}
    count:=core.count(perceivers)
    if count==0 {return}
    rays:=int(settings.rays) if settings.ptr!=nil else 256
    // Without rays nobody looks, and all remember as time goes.
    sighted:=rays>0
    first:=int(turns.next)%count
    for k in 0..<count {
        row:=(first+k)%count
        e:=core.entity_at(perceivers,row)
        p:=perceivers.table.values[row]
        mine:=core.edit(perceptions,e)
        pose,placed:=core.get(worlds,e)
        if mine==nil || !placed {continue}
        // Only those whose turn came look and forget: the others keep what they could not look at.
        turn:=rays>0 || !sighted
        eye:=pose.position+mm.Vec3{0,p.eyes,0}
        forward:=mm.quat_forward(pose.rotation)
        for target in 0..<core.count(perceivables) {
            if rays<=0 {break}
            subject:=core.entity_at(perceivables,target)
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
            if ai.memory_perceive(&mine.memory,u64(subject),at.position,.Sight,1,now)==.New {
                core.push(&events.queue,Perception_Event{kind=.Noticed,perceiver=e,subject=subject,sense=.Sight,position=at.position})
            }
        }
        if turn && sighted && rays<=0 && k+1<count {turns.next=u32((row+1)%count)}
        hear(&mine.memory,e,p,pose.position,heard,events,now)
        if turn {forget(&mine.memory,e,p,events,entities.ptr,now)}
    }
}

// What the perceivers far from the players perceive, at the ticks their
// brains decide in: what they notice in their cone and range, on or far
// itself, as if nothing hid it (the collision there is not loaded), and the
// noises of the tick; then they forget.
@(private)
perceive_far :: proc(perceivers:core.Read(Perceiver),perceptions:^core.Table(Perception),perceivables:core.Read(Perceivable),worlds:core.Read(core.World_Transform),fars:core.Read(nav.Nav_Far),heard:[]Noise,events:^Perception_Events,entities:^core.Entities,now:f64) {
    if fars.table==nil {return}
    far_of :: proc(fars:core.Read(nav.Nav_Far),e:core.Entity) -> bool {return core.raw_find(core.raw(fars.table),type_info_of(nav.Nav_Far),e)!=nil}
    for row in core.count(perceivers)..<len(perceivers.table.entities) {
        e:=perceivers.table.entities[row]
        if !far_of(fars,e) {continue}
        p:=perceivers.table.values[row]
        mine:=cast(^Perception)core.raw_edit(core.raw(perceptions),type_info_of(Perception),e)
        pose,placed:=core.get(worlds,e)
        if mine==nil || !placed {continue}
        eye:=pose.position+mm.Vec3{0,p.eyes,0}
        forward:=mm.quat_forward(pose.rotation)
        for target in 0..<len(perceivables.table.entities) {
            subject:=perceivables.table.entities[target]
            if subject==e || target>=core.count(perceivables) && !far_of(fars,subject) {continue}
            seen:=perceivables.table.values[target]
            if u32(p.notices)&(1<<u32(seen.team))==0 {continue}
            at,ok:=core.get(worlds,subject)
            if !ok || !ai.sight_in_cone(eye,forward,at.position+mm.Vec3{0,seen.point,0},p.sight,p.angle) {continue}
            if ai.memory_perceive(&mine.memory,u64(subject),at.position,.Sight,1,now)==.New {
                core.push(&events.queue,Perception_Event{kind=.Noticed,perceiver=e,subject=subject,sense=.Sight,position=at.position})
            }
        }
        hear(&mine.memory,e,p,pose.position,heard,events,now)
        forget(&mine.memory,e,p,events,entities,now)
    }
}

@(private)
hear :: proc(memory:^ai.Perception_Memory,e:core.Entity,p:Perceiver,position:mm.Vec3,heard:[]Noise,events:^Perception_Events,now:f64) {
    for n in heard {
        if !(n.loudness>0) || linalg.length(mm.Vec3(n.position)-position)>n.loudness*p.hearing {continue}
        if ai.memory_perceive(memory,u64(n.maker),n.position,.Hearing,0.75,now)==.New {
            core.push(&events.queue,Perception_Event{kind=.Noticed,perceiver=e,subject=n.maker,sense=.Hearing,position=n.position})
        }
    }
}

// Forgets at once what was destroyed (its handle names nothing), and the
// rest `forget` seconds after it was last perceived.
@(private)
forget :: proc(memory:^ai.Perception_Memory,e:core.Entity,p:Perceiver,events:^Perception_Events,entities:^core.Entities,now:f64) {
    gone:[ai.PERCEPTION_CAPACITY]u64
    dead:=0
    for o in memory.items[:clamp(memory.count,0,ai.PERCEPTION_CAPACITY)] {
        if o.subject!=0 && !core.alive(entities,core.Entity(o.subject)) {gone[dead]=o.subject;dead+=1}
    }
    for subject in gone[:dead] {
        ai.memory_remove(memory,subject)
        core.push(&events.queue,Perception_Event{kind=.Forgot,perceiver=e,subject=core.Entity(subject)})
    }
    forgotten:=ai.memory_forget(memory,now,p.forget,gone[:])
    for subject in gone[:min(forgotten,len(gone))] {
        core.push(&events.queue,Perception_Event{kind=.Forgot,perceiver=e,subject=core.Entity(subject)})
    }
}
