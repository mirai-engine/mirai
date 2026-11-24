package vfx

import "core:math"
import "core:math/linalg"
import "mirai:core"
import erender "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import mm "mirai:std/math"
import "plugins:vfx/runtime/effect"

// Dynamic point lights emitted by particle effects.
//
// Each emitter whose resolved Particle_Info sets light.intensity > 0 and
// light.range > 0 drives up to EMITTER_LIGHTS_MAX bounded erender.Point_Light
// nodes from a preallocated world pool of PARTICLE_LIGHTS_MAX transient
// entities (no core.Id: never saved in scenes, outliner or editor history).
// Color, intensity, range and analytical offset follow the effect's light
// config, color_over_life, size_over_life and the emitter's live clock births.
// When no emitter enables lights (clocks.lit_count == 0) and none are active,
// particles_lights returns in O(1) with zero work and zero allocations.

PARTICLE_LIGHTS_MAX :: 32 // hard preallocated world cap on particle-emitted point lights
EMITTER_LIGHTS_MAX :: 4   // hard per-emitter cap on concurrent point lights

@(component,derived,description="Derived transient point light owned by a Particle_Emitter.")
Particle_Light_Node :: struct {
    owner:core.Entity `mirai:"readonly"`,
}

Particle_Light_Slot :: struct {
    entity:core.Entity, // transient entity (no core.Id) holding Transform, Parent and Point_Light
    owner:core.Entity,  // emitter currently driving this slot; NONE when parked
    parent:core.Entity, // current Parent.entity of entity
    transform:core.Transform,
    light:erender.Point_Light,
    active:bool,
}

// Derived state of particle-emitted point lights for one world. Plain copyable
// fixed storage: Play copies and rollbacks keep matching handles with their tables.
@(storage)
Particle_Lights :: struct {
    slots:[PARTICLE_LIGHTS_MAX]Particle_Light_Slot,
    active_count:u32,
    pool_count:u32,
}

@(private="file")
Light_Candidate :: struct {
    owner:core.Entity,
    layer:u8,
    sample:u8,
    distance:f32,
    transform:core.Transform,
    light:erender.Point_Light,
}

// Updates the world's bounded pool of particle-emitted Point_Lights before
// transforms_propagate (late/end) and render_sync (render). Uses core.World_Ref
// so games that write erender.Point_Light directly never hit a single-writer
// conflict. Zero cost when disabled; zero allocations once slots are warm.
@(step="late",loops="game editor",stage="intent")
particles_lights :: proc(
    world:core.World_Ref,
    emitters:^core.Table(Particle_Emitter,.Read),
    overrides:^core.Table(Particle_Override,.Read),
    worlds:^core.Table(core.World_Transform,.Read),
    hidden:^core.Table(erender.Hidden,.Read),
    parents:^core.Table(core.Parent,.Read),
    clocks:core.Ref(Particle_Clocks),
    settings:core.Ref(Particle_Settings),
    lights:^Particle_Lights,
    sources:core.Ref(scene.Simulation_Sources),
    assets:^host.Assets,
) {
    if clocks.ptr==nil || lights==nil {return}
    if clocks.lit_count==0 && lights.active_count==0 {return}
    es:=core.world_entities(world)
    points:=core.world_table_of(world,erender.Point_Light)
    transforms:=core.world_table_of(world,core.Transform)
    if es==nil || points==nil || transforms==nil {return}
    parent_table:=core.world_table_of(world,core.Parent)
    nodes:=core.world_table_of(world,Particle_Light_Node)

    lights_prune(lights,es,points)

    budget:=PARTICLE_LIGHTS_MAX
    if settings.ptr!=nil {budget=min(int(settings.max_lights),PARTICLE_LIGHTS_MAX)}

    candidates:[PARTICLE_LIGHTS_MAX]Light_Candidate
    cand_count:=0
    if budget>0 && clocks.lit_count>0 {
        placed:=core.join(emitters,worlds)
        for e,emitter,wt in core.each_joined(&placed) {
            primary:=clock_find(clocks.ptr,e)
            if primary==nil || primary.culled {continue}
            if erender.is_hidden(hidden,parents,e) {continue}
            override,_:=core.get(overrides,e)
            for layer in 0..=int(primary.layers) {
                clock:=clock_find(clocks.ptr,e,layer)
                if clock==nil || !clock.emission.has_light || clock.done || clock.last<=-max(f64)*0.5 {continue}
                info:=particle_resolve(assets,emitter.particle,&override,emitter.preset,u8(layer))
                if info.light.intensity<=0 || info.light.range<=0 {continue}
                emitter_light_candidates(e,u8(layer),wt.transform,clock,&info,sources.ptr,budget,&candidates,&cand_count)
            }
        }
    }

    // Sticky slot assignment: match candidates to slots already owned by the same
    // emitter first so Parent and Transform stay untouched on steady ticks.
    slot_used:[PARTICLE_LIGHTS_MAX]bool
    cand_slot:[PARTICLE_LIGHTS_MAX]int
    for i in 0..<cand_count {cand_slot[i]=-1}

    for i in 0..<cand_count {
        cand:=&candidates[i]
        for s in 0..<int(lights.pool_count) {
            if slot_used[s] {continue}
            if lights.slots[s].owner==cand.owner || (!lights.slots[s].active && lights.slots[s].parent==cand.owner) {
                slot_used[s]=true
                cand_slot[i]=s
                break
            }
        }
    }
    for i in 0..<cand_count {
        if cand_slot[i]>=0 {continue}
        for s in 0..<int(lights.pool_count) {
            if slot_used[s] {continue}
            slot_used[s]=true
            cand_slot[i]=s
            break
        }
    }

    active:=u32(0)
    for i in 0..<cand_count {
        cand:=&candidates[i]
        s:=cand_slot[i]
        if s<0 {
            if int(lights.pool_count)>=PARTICLE_LIGHTS_MAX {continue}
            s=int(lights.pool_count)
            e:=core.create(es)
            if e==core.NONE {continue}
            core.add(transforms,e,cand.transform)
            if parent_table!=nil {core.add(parent_table,e,core.Parent{entity=cand.owner})}
            core.add(points,e,cand.light)
            if nodes!=nil {core.add(nodes,e,Particle_Light_Node{owner=cand.owner})}
            lights.slots[s]={
                entity=e,
                owner=cand.owner,
                parent=cand.owner,
                transform=cand.transform,
                light=cand.light,
                active=true,
            }
            lights.pool_count+=1
            slot_used[s]=true
            active+=1
            continue
        }
        slot:=&lights.slots[s]
        e:=slot.entity
        if slot.parent!=cand.owner && parent_table!=nil {
            table_put(parent_table,e,core.Parent{entity=cand.owner})
            slot.parent=cand.owner
        }
        if slot.transform!=cand.transform {
            table_put(transforms,e,cand.transform)
            slot.transform=cand.transform
        }
        if !slot.active || slot.light!=cand.light {
            table_put(points,e,cand.light)
            slot.light=cand.light
        }
        if nodes!=nil && slot.owner!=cand.owner {
            table_put(nodes,e,Particle_Light_Node{owner=cand.owner})
        }
        slot.owner=cand.owner
        slot.active=true
        active+=1
    }

    // Park unused slots at zero intensity so render_sync removes them from the
    // GPU light list without destroying entities or allocating on reuse.
    for s in 0..<int(lights.pool_count) {
        if slot_used[s] {continue}
        slot:=&lights.slots[s]
        if !slot.active {continue}
        table_put(points,slot.entity,erender.Point_Light{color={},intensity=0,range=0,radius=0,shadows=false,indirect=0,scattering=0})
        slot.light={}
        slot.owner=core.NONE
        slot.active=false
    }
    lights.active_count=active
}

@(private="file")
table_put :: proc(t:^core.Table($T),e:core.Entity,value:T) {
    if row:=core.staged(t,e);row!=nil {row^=value} else {core.add(t,e,value)}
}

// Drops slots whose transient light entity or parent emitter was destroyed.
@(private="file")
lights_prune :: proc(lights:^Particle_Lights,es:^core.Entities,points:^core.Table(erender.Point_Light)) {
    i:=0
    for i<int(lights.pool_count) {
        slot:=&lights.slots[i]
        entity_alive:=core.alive(es,slot.entity)
        parent_dead:=slot.parent!=core.NONE && !core.alive(es,slot.parent)
        if !entity_alive || parent_dead {
            if entity_alive {
                if row:=core.staged(points,slot.entity);row!=nil {row^={}}
                core.destroy(es,slot.entity)
            }
            last:=int(lights.pool_count)-1
            lights.slots[i]=lights.slots[last]
            lights.slots[last]={}
            lights.pool_count-=1
            continue
        }
        i+=1
    }
}

// Samples up to EMITTER_LIGHTS_MAX live light candidates for one emitter layer
// from its clock births, effect light config, color_over_life and size_over_life.
@(private="file")
emitter_light_candidates :: proc(
    owner:core.Entity,layer:u8,owner_world:mm.Transform,clock:^Emitter_Clock,info:^effect.Particle_Info,
    sources:^scene.Simulation_Sources,budget:int,candidates:^[PARTICLE_LIGHTS_MAX]Light_Candidate,count:^int,
) {
    longest:=max(info.lifetime[0],info.lifetime[1])
    if longest<=0 {return}
    min_age:=max(f64)
    max_age:=f64(-1)
    live_particles:=u64(0)
    for b in clock.births[:clock.birth_count] {
        instants:=birth_instants(b)
        t_first:=b.time
        t_last:=b.time+f64(instants-1)*f64(b.spacing)
        if clock.time<t_first {continue}
        newest_age:=max(clock.time-t_last,0)
        if newest_age>=f64(longest) {continue}
        oldest_age:=min(clock.time-t_first,f64(longest))
        min_age=min(min_age,newest_age)
        max_age=max(max_age,oldest_age)
        live_particles+=u64(b.count)
    }
    if live_particles==0 {
        // Program-driven GPU births track clock.last without CPU birth groups.
        if clock.emission.program_births && clock.last>-max(f64)*0.5 {
            age:=clock.time-clock.last
            if age>=0 && age<f64(longest) {
                min_age,max_age,live_particles=age,age,1
            }
        }
    }
    if live_particles==0 || min_age>=f64(longest) {return}

    want:=int(info.light.max_lights) if info.light.max_lights>0 else 1
    want=clamp(want,1,EMITTER_LIGHTS_MAX)
    if u64(want)>live_particles {want=int(live_particles)}

    base_color:=info.light.color
    if base_color=={} {base_color=0.5*(info.colors[0].rgb+info.colors[1].rgb)}
    avg_speed:=0.5*(info.speed[0]+info.speed[1])
    local_v0:=0.5*(info.velocity[0]+info.velocity[1])+[3]f32{0,avg_speed,0}

    for k in 0..<want {
        age:f64
        if want==1 {
            age=0.5*(min_age+max_age) if max_age>min_age+1e-4 else min_age
        } else {
            frac:=(f64(k)+0.5)/f64(want)
            age=min_age+(max_age-min_age)*frac
        }
        if age<0 || age>=f64(longest) {continue}
        u:=clamp(f32(age)/longest,0,1)
        grad:=keys_at(info.color_over_life.times[:],info.color_over_life.colors[:],u)
        size_mul:=keys_at(info.size_over_life.times[:],info.size_over_life.values[:],u)
        envelope:=clamp(grad.a,0,1)
        if envelope<=1e-4 || size_mul<=0 {continue}
        intensity:=info.light.intensity*envelope
        range:=info.light.range*clamp(size_mul,0.1,4)
        if intensity<=1e-4 || range<=1e-4 {continue}

        color:=[3]f32{
            max(base_color.r*grad.r,0),
            max(base_color.g*grad.g,0),
            max(base_color.b*grad.b,0),
        }
        if color.r+color.g+color.b<=1e-6 {continue}

        spread:=light_shape_spread(info,k,want)
        t:=f32(age)
        world_pos:mm.Vec3
        if info.local_space {
            local_pos:=spread+local_v0*t+0.5*info.acceleration*(t*t)
            world_pos=mm.transform_point(owner_world,local_pos)
        } else {
            world_v0:=mm.quat_rotate(owner_world.rotation,local_v0)
            world_spread:=mm.quat_rotate(owner_world.rotation,owner_world.scale*spread)
            world_pos=owner_world.position+world_spread+world_v0*t+0.5*info.acceleration*(t*t)
        }
        rel,ok:=mm.transform_relative(mm.Transform{position=world_pos,rotation=1,scale={1,1,1}},owner_world)
        if !ok {rel=mm.TRANSFORM_IDENTITY}

        cand:=Light_Candidate{
            owner=owner,
            layer=layer,
            sample=u8(k),
            distance=scene.sources_distance(sources,world_pos,world_pos),
            transform=core.Transform{position=rel.position,rotation=rel.rotation,scale=rel.scale},
            light={
                color=color,
                intensity=intensity,
                range=range,
                radius=info.light.radius,
                shadows=info.light.shadows,
                indirect=info.light.indirect,
                scattering=info.light.scattering,
            },
        }
        candidate_insert(candidates,count,budget,cand)
    }
}

// Deterministic small spread across the emitter shape when emitting >1 light.
@(private="file")
light_shape_spread :: proc "contextless" (info:^effect.Particle_Info,index,total:int) -> [3]f32 {
    if total<=1 || info.shape==.Point {return {}}
    t:=f32(index)/f32(total-1)*2-1 // -1..1
    #partial switch info.shape {
    case .Line: return {0,info.shape_size.x*t,0}
    case .Box:  return {info.shape_size.x*t*0.5,0,0}
    case .Circle,.Sphere,.Hemisphere,.Cone:
        angle:=f32(index)*math.TAU/f32(total)
        r:=info.shape_size.x*0.5
        return {math.cos(angle)*r,0,math.sin(angle)*r}
    }
    return {}
}

// Keeps the top `budget` candidates in deterministic priority order: nearest
// simulation source, then brightest intensity, then entity/layer/sample.
@(private="file")
candidate_insert :: proc "contextless" (candidates:^[PARTICLE_LIGHTS_MAX]Light_Candidate,count:^int,budget:int,cand:Light_Candidate) {
    limit:=min(budget,PARTICLE_LIGHTS_MAX)
    if limit<=0 {return}
    pos:=count^
    for pos>0 && candidate_before(cand,candidates[pos-1]) {pos-=1}
    if pos>=limit {return}
    new_count:=min(count^+1,limit)
    for i:=new_count-1;i>pos;i-=1 {candidates[i]=candidates[i-1]}
    candidates[pos]=cand
    count^=new_count
}

@(private="file")
candidate_before :: proc "contextless" (a,b:Light_Candidate) -> bool {
    if a.distance!=b.distance {return a.distance<b.distance}
    if a.light.intensity!=b.light.intensity {return a.light.intensity>b.light.intensity}
    if a.owner!=b.owner {return a.owner<b.owner}
    if a.layer!=b.layer {return a.layer<b.layer}
    return a.sample<b.sample
}
