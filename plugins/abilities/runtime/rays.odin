package abilities

import "core:math"
import "core:math/linalg"
import audio "mirai:engine/audio"
import "mirai:core"
import inp "mirai:engine/input"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import anim "plugins:animation/runtime"
import phys "plugins:physics/runtime"

// Rays: a hitbox of shape Ray casts its pellets the tick its window opens, from the aim of the seat
// that drives the user (or its wielder) or from the user itself. abilities_step only writes them
// down in Ability_Shots; abilities_shots, after it in the tick, resolves each against the physics
// query and then the hit zones of what it reached (anim.Hit_Zone_Set), and applies the effect the
// tags of the target and of its zone pick. A library that sees the world as the player who aimed
// saw it resolves them in between (abilities_multiplayer, on a server). The spread of each pellet
// comes from the tick, the user and the pellet, so every end and every tick run again cast the same
// rays.

// What abilities_shots reads to resolve and apply the pellets of a tick.
@(params)
Shot_World :: struct {
    physics:core.Ref(phys.Physics_State),
    zone_sets:^core.Table(anim.Hit_Zone_Set,.Read),
    zone_poses:^core.Table(anim.Hit_Zone_Pose,.Read),
    zones:core.Records(anim.Hit_Zones),
    tags:^core.Table(scene.Tags,.Read),
    remotes:^core.Table(core.Remote,.Read),
    sounds:^audio.Sound_Requests,
    births:^core.Births,
    problems:^core.Problems,
}

// Resolves the pellets of the tick that no one resolved before and applies them: a Shot for each,
// a Hit for what it reached with the effect its tags pick, where this end decides the user. Nothing
// runs in a tick without pellets.
@(step="fixed",loops="game",after="abilities_step")
abilities_shots :: proc(shots:^Ability_Shots,data:Ability_Data,sheets:core.Ref(Ability_Sheets),requests:^Ability_Requests,events:^Ability_Events,w:Shot_World) {
    if shots.count==0 && shots.dropped==0 {return}
    w:=w
    if shots.dropped>0 {
        core.report(w.problems,core.NONE,"abilities.shots","%d pellets of ray hitboxes were not cast in a tick: more than %d at once; cast fewer pellets in a tick",shots.dropped,SHOTS)
    }
    pushed:=0
    for &shot in shots.items[:min(shots.count,SHOTS)] {
        if !shot.resolved {shot.hit=shot_cast(&w,&shot)}
        hit:=shot.hit
        event:=Ability_Event{entity=shot.user,ability=shot.ability,window=shot.window,zone=hit.zone,target=hit.entity,origin=shot.origin,point=hit.point,normal=hit.normal,distance=hit.distance}
        event.kind=.Shot
        shot_event(events,event,&pushed,w.problems)
        h:=record_at(data.hitboxes,int(shot.hitbox))
        if hit.entity==core.NONE || h==nil {continue}
        event.kind=.Hit
        shot_event(events,event,&pushed,w.problems)
        tags:scene.Tags
        if w.tags!=nil {tags,_=core.get(w.tags,hit.entity)}
        tags.bits|=hit.tags.bits
        at:=hitbox_effect_at(h,tags)
        if at<0 {continue}
        effect:=h.effect if at==0 else h.target_effects[at-1]
        if sheets.ptr!=nil && int(shot.hitbox)<len(sheets.hit_channels) {
            rotation:=mm.quat_between([3]f32{0,1,0},hit.normal) if hit.normal!={} else 1
            audio.cue_play(w.sounds,w.births,effect.on_hit,sheets.hit_channels[shot.hitbox][at],mm.Transform{hit.point,rotation,1},hit.entity)
        }
        // Only the end that decides the user applies what it hits; the others show it.
        if !core.owned(w.remotes,shot.user) {continue}
        // The tags picked it already: the zone's are not the target's own.
        effect.target_tags={}
        if effect!={} {ability_effect(requests,hit.entity,effect,shot.user)}
    }
    shots.count,shots.dropped=0,0
}

@(private)
shot_event :: proc(events:^Ability_Events,event:Ability_Event,pushed:^int,problems:^core.Problems) {
    if events==nil {return}
    if pushed^>=EVENT_CAPACITY || len(events.queue.items)>=cap(events.queue.items) {
        core.report(problems,core.NONE,"abilities.events","ability event capacity reached: remaining events were dropped")
        return
    }
    pushed^+=1
    core.push(&events.queue,event)
}

// Where a pellet stops in the world as it is now: the nearest collider it reaches whose entity has
// no placed hit zones, or the zone it meets of one that has them; it passes beside the zones of an
// entity through its collider, and through the colliders of passes (what lag compensation judges
// where it was), up to RAY_PASSES colliders. Who aimed it (or its user) is not hit.
shot_cast :: proc(w:^Shot_World,shot:^Ability_Shot,passes:[]core.Entity=nil) -> (hit:Shot_Hit) {
    hit.zone=-1
    traveled:f32
    ignore:=shot.aim if shot.aim!=core.NONE else shot.user
    for _ in 0..<RAY_PASSES {
        left:=shot.range-traveled
        if !(left>0) {break}
        from:=shot.origin+shot.direction*traveled
        found,ok:=ray_query(w.physics,from,shot.direction,left,shot.radius,ignore)
        if !ok {break}
        passed:=false
        for e in passes {if e==found.entity {passed=true;break}}
        if passed {
            traveled+=found.distance+RAY_STEP
            ignore=found.entity
            continue
        }
        if found.entity!=core.NONE && anim.hit_zones_placed(w.zone_poses,found.entity) {
            if zone,met:=anim.hit_zones_ray(w.zone_poses,w.zone_sets,w.zones,found.entity,from,shot.direction,left,shot.radius);met {
                return {entity=found.entity,point=zone.point,normal=zone.normal,distance=traveled+zone.distance,zone=i8(zone.zone),tags=zone.tags}
            }
            traveled+=found.distance+RAY_STEP
            ignore=found.entity
            continue
        }
        return {entity=found.entity,point=found.point,normal=found.normal,distance=traveled+found.distance,zone=-1}
    }
    hit.distance=shot.range
    hit.point=shot.origin+shot.direction*shot.range
    return
}

// How far past a collider whose zones a pellet missed it goes on from, metres.
RAY_STEP :: f32(0.01)

// The nearest collider along a ray, thin or a sphere of radius swept along it.
ray_query :: proc(physics:core.Ref(phys.Physics_State),from,direction:[3]f32,distance,radius:f32,ignore:core.Entity) -> (phys.Hit,bool) {
    if radius>0 {return phys.sweep(physics,phys.Sphere{radius},from,1,direction,distance,ignore)}
    return phys.raycast(physics,from,direction,distance,ignore)
}

// The rays and self hits of the windows of a that open at this tick: their pellets go to Ability_Shots,
// which apply them where this end decides the user (decides) and only show them elsewhere.
@(private)
rays :: proc(t:^Tick,e:core.Entity,u:^Actor,a:^Ability,before,at:Ability_Time,decides:bool) {
    for &w,i in a.windows {
        if w.hitbox=={} || !ability_window_open(w,t.dt,at,i) || ability_window_open(w,t.dt,before,i) {continue}
        row:=record_row(t.hitboxes,w.hitbox)
        h:=record_at(t.hitboxes,row)
        if h==nil {continue}
        #partial switch h.shape {
        case .Ray: shots_add(t,e,u,h,row,i)
        case .Self:
            // One without an effect only kicks the look: a recovery.
            if !decides || h.effect=={} {continue}
            event_push(t,{kind=.Hit,entity=e,ability=u.state.ability,window=i8(i),zone=-1,cue=w.cue,target=e})
            if row<len(t.sheets.hit_channels) {cue_emit(t,h.effect.on_hit,t.sheets.hit_channels[row][0],e)}
            effect:=h.effect
            effect.target_tags={}
            ability_effect(t.requests,e,effect,e)
        }
    }
}

// Writes down the pellets of the Ray hitbox h of window of e for abilities_shots.
@(private)
shots_add :: proc(t:^Tick,e:core.Entity,u:^Actor,h:^Ability_Hitbox,row,window:int) {
    shots:=t.w.shots
    if shots==nil {return}
    origin:[3]f32
    rotation:=mm.Quat(1)
    aim:=core.NONE
    if h.ray.from==.Aim {
        if o,_,r,ok:=inp.aim({t.w.seats,t.w.seat_states,t.w.worlds,t.w.verticals},u.driver);ok {origin,rotation,aim=o,r,u.driver}
    }
    if aim==core.NONE {
        placed,found:=core.get(t.w.worlds,e)
        pose:=placed.transform if found else mm.TRANSFORM_IDENTITY
        if at,socket:=socket_pose(t,e,u,base.text_get(h.socket[:]));socket {pose=at}
        origin,rotation=hitbox_world(h,pose)
    }
    seed:=base.hash_mix(base.hash_mix(t.tick,u64(core.id_of(t.w.ids,e))),u64(u.state.start)<<8|u64(window))
    spread:=math.tan(clamp(h.ray.spread,0,1.5))
    range:=h.ray.range if h.ray.range>0 else RAY_RANGE
    for pellet in 0..<clamp(int(h.ray.pellets),1,RAY_PELLETS) {
        local:=[3]f32{0,0,-1}
        if spread>0 {
            rng:=mm.rng_make(base.hash_mix(seed,u64(pellet)))
            disc:=mm.random_in_disc(&rng)*spread
            local={disc.x,disc.y,-1}
        }
        if shots.count>=SHOTS {shots.dropped+=1;continue}
        shots.items[shots.count]={
            user=e,aim=aim,ability=u.state.ability,hitbox=i32(row),window=i8(window),
            origin=origin,direction=linalg.normalize(mm.quat_rotate(rotation,local)),range=range,radius=h.ray.radius,
        }
        shots.count+=1
    }
}

// The look kicks of the hitboxes of the windows of a open at this tick: evenly by tick over a window
// of the world clock, at once when one on a span or the own clock opens.
@(private)
kicks :: proc(t:^Tick,u:^Actor,a:^Ability,before,at:Ability_Time) {
    if t.w.kicks==nil {return}
    for &w,i in a.windows {
        if w.hitbox=={} || !ability_window_open(w,t.dt,at,i) {continue}
        h:=record_sheet(t.hitboxes,w.hitbox)
        if h==nil || h.kick=={} {continue}
        kick:=h.kick
        if w.span[0]==0 && w.clock==.World {
            from,to:=window_ticks(w,t.dt)
            kick/=f32(to-from)
        } else if ability_window_open(w,t.dt,before,i) {continue}
        inp.look_kick(t.w.kicks,u.driver,kick.x,kick.y)
    }
}

// Plays the on_begin of window w where its hitbox says: at its socket, at the muzzle of a ray (its
// center in the axes of the user), or at the user.
@(private)
window_cue :: proc(t:^Tick,e:core.Entity,u:^Actor,w:^Ability_Window,channel:core.Birth_Channel) {
    if w.on_begin.sound=={} && channel==0 {return}
    if h:=record_sheet(t.hitboxes,w.hitbox);h!=nil {
        if h.socket[0]!=0 {
            if pose,placed:=socket_pose(t,e,u,base.text_get(h.socket[:]));placed {
                audio.cue_play(t.w.sounds,t.w.births,w.on_begin,channel,pose,e)
                return
            }
        } else if h.shape==.Ray {
            if placed,found:=core.get(t.w.worlds,e);found {
                center,rotation:=hitbox_world(h,placed.transform)
                audio.cue_play(t.w.sounds,t.w.births,w.on_begin,channel,mm.Transform{center,rotation,1},e)
                return
            }
        }
    }
    cue_emit(t,w.on_begin,channel,e)
}

// Where a socket (or a bone) of the skeleton of e is, else of the rig e hangs from (Bone_Attachment),
// else of its wielder: a problem of e when none has it.
@(private)
socket_pose :: proc(t:^Tick,e:core.Entity,u:^Actor,name:string) -> (mm.Transform,bool) {
    if name=="" {return {},false}
    rigs:=[3]core.Entity{e,core.NONE,u.driver}
    if t.w.attachments!=nil {
        if attached,found:=core.get(t.w.attachments,e);found {rigs[1]=attached.rig}
    }
    for rig in rigs {
        if rig==core.NONE {continue}
        if pose,placed:=anim.animation_socket_world(t.w.playback,t.w.skeletons,rig,name);placed {return pose,true}
    }
    core.report(t.w.problems,e,"abilities.socket","a hitbox of %s names the socket '%s', which neither its skeleton, the rig it hangs from nor its wielder's has posed; name a socket of one of them (skeleton.socket.set), or clear socket",core.record_name(t.abilities,u.state.ability),name)
    return {},false
}
